// GERA a config unificada a partir dos kong.yml de cada projeto.
//
// Por que um GERADOR e não uma cópia: durante a transição os projetos continuam
// vivos e mexendo nos próprios gateways. Uma cópia manual nasce desatualizada na
// primeira rota nova, e a divergência aparece como "funciona no Kong antigo e
// some no novo" — o pior tipo de bug para achar.
//
// Rodar de novo é barato e sempre reflete a verdade:
//
//     node scripts/gerar-kong.mjs
//
// ---------------------------------------------------------------------------
// O QUE ELE FAZ ALÉM DE JUNTAR
// ---------------------------------------------------------------------------
// 1. Prefixa nomes de service/route com o projeto — `liveflow-app` e
//    `sigma-app` já são únicos, mas rotas como `home` não são.
// 2. **Injeta `hosts:` em toda rota.** É o coração da unificação: hoje nenhum
//    dos cinco declara host, e sete caminhos (`/`, `/admin`, `/api/webhooks`…)
//    são disputados por dois ou três projetos. Sem host, o Kong entrega a página
//    do projeto errado sem registrar erro. Ver docs/mapeamento.md.
// 3. **Reprova** se algum projeto não tiver host declarado aqui: melhor falhar
//    na geração do que descobrir em produção que `/` virou roleta.
import { readFile, writeFile, mkdir } from "node:fs/promises";
import path from "node:path";
import { parseDocument } from "yaml";

const WORKSPACE = path.resolve("..");

/**
 * Cada projeto, sua config e os domínios que o atendem HOJE (tirados do
 * config.yml do cloudflared). O host é o que separa um projeto do outro no
 * gateway único.
 */
const PROJETOS = [
  {
    id: "liveflow",
    config: "live-flow/deploy/kong/kong.yml",
    hosts: ["urupix.com.br", "www.urupix.com.br", "urupix.cursodetecnologia.dev.br"],
    redes: ["live-flow_default"],
  },
  {
    id: "sigmafin",
    config: "sigma-financeiro/deploy/kong/kong.yml",
    hosts: ["sigma-financeiro.cursodetecnologia.dev.br"],
    redes: ["sigma-financeiro_default"],
  },
  {
    id: "plataforma",
    config: "cafe-mobile-erp/kong/kong.yml",
    hosts: ["cafe-api.cursodetecnologia.dev.br"],
    redes: ["cafe-mobile-erp_default"],
  },
  {
    id: "central",
    config: "central-ia/deploy/kong/kong.yml",
    // sem domínio público ainda — atendido por porta local. Fica um host
    // interno para a rota não virar curinga e roubar `/` dos outros.
    hosts: ["central.interno"],
    redes: ["central-ia_default"],
  },
  {
    id: "sigmapay",
    config: "sigma-payments/infra/kong/kong.yml",
    hosts: ["sigma-payments.interno"],
    redes: [],
  },
];

/** Plugins presentes nos CINCO — sobem para global em vez de repetir 5×. */
const GLOBAIS = ["correlation-id", "cors", "prometheus"];

const erros = [];

/**
 * Injeta `hosts:` em TODA rota, prefixa nomes com o projeto e devolve o bloco
 * `services` pronto.
 *
 * 🐞 A primeira versão fazia isso com regex sobre o texto do YAML e injetava
 * `hosts:` também em PLUGINS e em SERVICES — 76 injeções onde cabiam ~30.
 * Config de gateway errada não estoura: ela entrega a página do projeto errado
 * calada. YAML aninhado se lê com parser, não com expressão regular.
 *
 * `parseDocument` preserva os comentários, e eles importam: cada rota carrega o
 * histórico de bugs que a moldou (o `read_timeout` de 1 h do SSE, o
 * `host.docker.internal` que derrubou o site em 04/08).
 */
function prepararServices(yamlTexto, hosts, projetoId) {
  const doc = parseDocument(yamlTexto);
  const services = doc.get("services");
  if (!services || !services.items) return null;

  let rotas = 0;
  const paresHostCaminho = [];

  for (const service of services.items) {
    // nome do SERVICE: prefixa, mas NÃO recebe hosts (host é de rota)
    const nomeSvc = service.get("name");
    if (nomeSvc && !String(nomeSvc).startsWith(projetoId)) {
      service.set("name", `${projetoId}-${nomeSvc}`);
    }

    const routes = service.get("routes");
    if (!routes?.items) continue;

    for (const rota of routes.items) {
      const nome = rota.get("name");
      if (nome && !String(nome).startsWith(projetoId)) {
        rota.set("name", `${projetoId}-${nome}`);
      }
      // é AQUI, e só aqui, que o host entra — plugin e service não têm host
      rota.set("hosts", hosts);
      rotas++;

      const paths = rota.get("paths");
      for (const p of paths?.items ?? []) {
        for (const h of hosts) paresHostCaminho.push({ host: h, path: String(p) });
      }
    }
  }
  return { doc, services, rotas, paresHostCaminho };
}

async function main() {
  const redes = new Set();
  const todosServices = [];
  const caminhosPorHost = new Map(); // "host|caminho" → projeto, para achar colisão

  for (const proj of PROJETOS) {
    if (!proj.hosts?.length) {
      erros.push(`${proj.id}: sem hosts declarados — a rota viraria curinga`);
      continue;
    }
    const caminho = path.join(WORKSPACE, proj.config);
    let yaml;
    try {
      yaml = await readFile(caminho, "utf8");
    } catch {
      erros.push(`${proj.id}: não achei ${proj.config}`);
      continue;
    }

    const preparado = prepararServices(yaml, proj.hosts, proj.id);
    if (!preparado) {
      erros.push(`${proj.id}: bloco services: vazio ou ilegível em ${proj.config}`);
      continue;
    }

    proj.redes.forEach((r) => redes.add(r));
    proj.rotas = preparado.rotas;
    // marca de qual projeto veio — o comentário sobrevive na saída
    preparado.services.commentBefore = ` ${proj.id.toUpperCase()} — de ${proj.config} (${preparado.rotas} rotas)\n hosts: ${proj.hosts.join(", ")}`;
    todosServices.push(...preparado.services.items);

    // COLISÃO: mesmo host + mesmo caminho em projetos diferentes é ambiguidade
    // que o Kong resolve por prioridade — ou seja, silenciosamente e errado.
    for (const { host, path: p } of preparado.paresHostCaminho) {
      const chave = `${host}|${p}`;
      const dono = caminhosPorHost.get(chave);
      if (dono && dono !== proj.id) {
        erros.push(`colisão: "${p}" no host "${host}" é reivindicado por ${dono} E ${proj.id}`);
      }
      caminhosPorHost.set(chave, proj.id);
    }
  }

  if (erros.length) {
    console.error("❌ Não gerei nada:\n" + erros.map((e) => "   • " + e).join("\n"));
    process.exit(1);
  }

  // monta UM documento só — emendar texto de YAML foi o erro da 1ª versão
  const saida = parseDocument(`_format_version: "3.0"
_transform: true
plugins: []
services: []
`);
  saida.commentBefore = ` GERADO por scripts/gerar-kong.mjs — NÃO editar à mão.

 Para mudar uma rota, mude no kong.yml do PROJETO e rode o gerador de novo.
 Editar aqui faz a mudança sumir na próxima geração, e ninguém entende por quê.

 Cada rota carrega \`hosts:\` porque sete caminhos são disputados por dois ou
 três projetos (/, /admin, /api/webhooks…). Sem host, o Kong entrega a página
 do projeto errado SEM registrar erro. Ver docs/mapeamento.md.`;
  saida.set(
    "plugins",
    GLOBAIS.map((name) => ({ name }))
  );
  saida.get("services").items = todosServices;

  await mkdir("kong", { recursive: true });
  await writeFile(path.join("kong", "kong.yml"), String(saida));

  const totalRotas = PROJETOS.reduce((n, p) => n + (p.rotas ?? 0), 0);
  console.log(`✅ kong/kong.yml — ${PROJETOS.length} projetos, ${todosServices.length} services, ${totalRotas} rotas`);
  console.log(`   todas as rotas com hosts; nenhuma colisão host+caminho`);
  console.log(`   redes do container: ${[...redes].join(", ")}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

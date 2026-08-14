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
// 4. **Reancora o bloco `plugins:` de topo dentro do projeto de origem.**
//
// 🐞 A primeira versão só copiava `services:` e substituía o `plugins:` de topo
// por três globais (`correlation-id`, `cors`, `prometheus`), assumindo que os
// cinco projetos os configuravam igual. NÃO configuravam: o `cors` tem CINCO
// listas de origens diferentes, e um `cors` global sem `config.origins` libera
// `*` — afrouxa todo mundo de uma vez. Junto foram embora 18 plugins, entre eles
// o `ip-restriction` do cafe-mobile-erp e o `X-Frame-Options: DENY` da central.
//
// Nada disso aparece no código HTTP: a rota responde 200 igual, só que sem a
// proteção. Foi encontrado comparando plugin a plugin, não navegando.
//
// Por isso agora NADA é global. Todo plugin nasce preso ao serviço ou à rota do
// projeto que o declarou — que é o único escopo em que a config dele é verdade.
import { readFile, writeFile, mkdir } from "node:fs/promises";
import path from "node:path";
import { Document, parseDocument } from "yaml";

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

// NÃO existe lista de plugins globais aqui, e é de propósito. `correlation-id`,
// `cors` e `prometheus` estão nos cinco projetos, mas com CONFIG DIFERENTE —
// `cors` tem cinco listas de origens distintas. Global significaria escolher a
// de um projeto e impor aos outros. Ver distribuirPlugins().

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
  // índices pelo nome ORIGINAL (sem prefixo): é assim que o bloco `plugins:` de
  // topo referencia as rotas, e é depois de renomear que a referência quebraria
  const porRota = new Map();
  const porServico = new Map();

  for (const service of services.items) {
    // nome do SERVICE: prefixa, mas NÃO recebe hosts (host é de rota)
    const nomeSvc = service.get("name");
    if (nomeSvc) porServico.set(String(nomeSvc), service);
    if (nomeSvc && !String(nomeSvc).startsWith(projetoId)) {
      service.set("name", `${projetoId}-${nomeSvc}`);
    }

    const routes = service.get("routes");
    if (!routes?.items) continue;

    for (const rota of routes.items) {
      const nome = rota.get("name");
      if (nome) porRota.set(String(nome), rota);
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
  return { doc, services, rotas, paresHostCaminho, porRota, porServico };
}

/**
 * Copia um nó do YAML preservando os comentários.
 *
 * Importa: o `response-transformer` da central-ia carrega a explicação de por
 * que usa `replace` e não `add` no `X-Frame-Options` (com `add` o plugin vira
 * no-op silencioso, porque o upstream já manda o cabeçalho). Perder o
 * comentário é perder o motivo — e alguém "simplifica" para `add` depois.
 */
function copiarNo(no) {
  return parseDocument(String(new Document(no))).contents;
}

/**
 * Reancora o bloco `plugins:` de topo dentro do projeto de origem.
 *
 * No Kong o plugin de topo pode ser escopado por `route:`/`service:`, ou não ter
 * escopo nenhum — e aí vale para o gateway inteiro. Num Kong por projeto isso
 * significa "todo o projeto"; num Kong único significa "todos os projetos", que
 * é coisa bem diferente. O `cors` do live-flow aplicado ao Sigma seria uma
 * política de origem trocada, sem erro nenhum no log.
 *
 * Então:
 *   • `route: X`   → vira plugin aninhado na rota X (nome original, pré-prefixo)
 *   • `service: X` → vira plugin aninhado no serviço X
 *   • sem escopo   → vira plugin aninhado em CADA serviço do projeto
 *
 * A precedência do Kong (rota > serviço) preserva as sobrescritas: o
 * cafe-mobile-erp tem `cors` do projeto E `cors` por rota, e a rota continua
 * ganhando, como ganhava antes.
 */
function distribuirPlugins(doc, projetoId, porRota, porServico, erros) {
  const topo = doc.get("plugins");
  if (!topo?.items?.length) return 0;

  const anexar = (alvo, pluginNo) => {
    let lista = alvo.get("plugins");
    if (!lista?.items) {
      alvo.set("plugins", doc.createNode([]));
      lista = alvo.get("plugins");
    }
    lista.items.push(pluginNo);
  };

  let anexados = 0;

  for (const plugin of topo.items) {
    const nome = String(plugin.get("name"));
    const rotaRef = plugin.get("route");
    const servicoRef = plugin.get("service");

    if (plugin.get("consumer")) {
      // nenhum projeto usa hoje; se passar a usar, o consumer é global no Kong e
      // precisa de decisão própria — melhor reprovar do que anexar no lugar errado
      erros.push(`${projetoId}: plugin "${nome}" escopado por consumer — não sei reancorar`);
      continue;
    }

    let alvos = [];
    if (rotaRef) {
      const alvo = porRota.get(String(rotaRef));
      if (!alvo) {
        erros.push(`${projetoId}: plugin "${nome}" aponta para a rota "${rotaRef}", que não existe`);
        continue;
      }
      alvos = [alvo];
    } else if (servicoRef) {
      const alvo = porServico.get(String(servicoRef));
      if (!alvo) {
        erros.push(`${projetoId}: plugin "${nome}" aponta para o service "${servicoRef}", que não existe`);
        continue;
      }
      alvos = [alvo];
    } else {
      alvos = [...porServico.values()];
      if (!alvos.length) {
        erros.push(`${projetoId}: plugin "${nome}" é do projeto inteiro, mas o projeto não tem services`);
        continue;
      }
    }

    for (const alvo of alvos) {
      const copia = copiarNo(plugin);
      copia.delete("route");
      copia.delete("service");
      anexar(alvo, copia);
      anexados++;
    }
  }

  // o bloco de topo fica vazio: no Kong único, "sem escopo" nunca é o que se quer
  doc.set("plugins", doc.createNode([]));
  return anexados;
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

    // reancora o `plugins:` de topo ANTES de levar os services embora — depois
    // disso o doc do projeto some e a referência não teria mais como ser lida
    proj.plugins = distribuirPlugins(
      preparado.doc,
      proj.id,
      preparado.porRota,
      preparado.porServico,
      erros
    );

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
 do projeto errado SEM registrar erro. Ver docs/mapeamento.md.

 \`plugins:\` de topo fica VAZIO de propósito. Todo plugin mora dentro do
 serviço ou da rota do projeto que o declarou: os cinco configuram
 \`cors\` de um jeito diferente, e um \`cors\` global sem \`origins\` libera \`*\`.`;
  // topo vazio: nada é global. Ver distribuirPlugins() e conferir-plugins.mjs.
  saida.set("plugins", saida.createNode([]));
  saida.get("services").items = todosServices;

  await mkdir("kong", { recursive: true });
  await writeFile(path.join("kong", "kong.yml"), String(saida));

  const totalRotas = PROJETOS.reduce((n, p) => n + (p.rotas ?? 0), 0);
  const totalPlugins = PROJETOS.reduce((n, p) => n + (p.plugins ?? 0), 0);
  console.log(`✅ kong/kong.yml — ${PROJETOS.length} projetos, ${todosServices.length} services, ${totalRotas} rotas`);
  console.log(`   todas as rotas com hosts; nenhuma colisão host+caminho`);
  console.log(`   ${totalPlugins} plugins de topo reancorados no projeto de origem (nenhum global)`);
  console.log(`   redes do container: ${[...redes].join(", ")}`);
  console.log(`   → confira com: npm run conferir`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

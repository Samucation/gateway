// CONFERE que o gateway roda com as MESMAS defesas de ambiente que cada Kong
// de projeto pedia — ou mais fortes, nunca mais fracas.
//
//     node scripts/conferir-ambiente.mjs
//
// ---------------------------------------------------------------------------
// POR QUE ESTE SCRIPT EXISTE
// ---------------------------------------------------------------------------
// Nem toda defesa mora no kong.yml. Metade das que importam são variáveis de
// ambiente do container, e `conferir-plugins.mjs` não enxerga nenhuma delas.
//
// Em 14/08/2026 o gateway subiu SEM `KONG_REAL_IP_HEADER`, que os quatro
// projetos declaravam. Sem ela o Kong toma por cliente quem abriu a conexão — e
// quem abre é sempre o `cloudflared`, da própria máquina. Resultado:
//
//   • `ip-restriction` que só libera faixa privada passa a liberar A INTERNET,
//     porque o túnel chega como faixa privada. Medido: a rota do operador do
//     cafe-mobile-erp devolvia 401 (chegou na aplicação) em vez de 404.
//   • `rate-limiting` com `limit_by: ip` põe todos os visitantes num balde só:
//     um abusador leva o resto a 429 junto.
//
// As duas falham CALADAS: a rota responde, o log parece normal, e o número que
// deveria denunciar (o IP) é justamente o que está errado.
//
// Compara contra o container RODANDO, não contra o docker-compose.yml: o que
// protege é o processo no ar. `liveflow-kong` é a prova de que os dois divergem
// — o compose dele declara as três variáveis e o container roda sem nenhuma.
import { readFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import path from "node:path";
import { promisify } from "node:util";

const exec = promisify(execFile);
const WORKSPACE = path.resolve("..");
// dá para apontar para outro container (`GATEWAY_CONTAINER=liveflow-kong`) — é
// assim que se prova que o guarda REPROVA de verdade, sem mexer no gateway
const CONTAINER = process.env.GATEWAY_CONTAINER ?? "gateway-kong";

// Onde procurar quando o Kong NÃO for um container Docker. Na VM ele é Pod.
const KUBECTL = process.env.GATEWAY_KUBECTL ?? "microk8s kubectl";
const NAMESPACE = process.env.GATEWAY_NAMESPACE ?? "gateway";
const ALVO = process.env.GATEWAY_ALVO ?? "deploy/kong";

const PROJETOS = [
  { id: "liveflow", compose: "live-flow/deploy/kong/docker-compose.yml" },
  { id: "sigmafin", compose: "sigma-financeiro/deploy/kong/docker-compose.yml" },
  { id: "plataforma", compose: "cafe-mobile-erp/docker-compose.yml" },
  { id: "central", compose: "central-ia/docker-compose.yml" },
  { id: "sigmapay", compose: "sigma-payments/docker-compose.yml" },
];

/**
 * As variáveis que são DEFESA, não afinação. Só estas reprovam.
 *
 * `KONG_NGINX_WORKER_PROCESSES` e `KONG_MEM_CACHE_SIZE` ficam de fora de
 * propósito: divergir nelas é decisão de capacidade, não brecha.
 */
const DEFESAS = {
  KONG_HEADERS: {
    porque: "não anunciar Via/Server/X-Kong — versão exata do gateway é meio caminho de uma varredura",
    aceita: (esperado, obtido) => esperado !== "off" || obtido === "off",
  },
  KONG_REAL_IP_HEADER: {
    porque: "sem ele o cliente é sempre o cloudflared, e ip-restriction/rate-limiting caem calados",
    // CF-Connecting-IP é mais forte que X-Forwarded-For: a Cloudflare
    // sobrescreve aquele na borda, este é lista e aceita item forjado na frente
    aceita: (esperado, obtido) =>
      obtido === esperado || (obtido === "CF-Connecting-IP" && esperado === "X-Forwarded-For"),
  },
  KONG_TRUSTED_IPS: {
    porque: "quem tem permissão de DIZER qual é o IP do cliente",
    aceita: (esperado, obtido) => {
      const norm = (s) =>
        new Set(
          String(s)
            .split(",")
            .map((x) => x.trim())
            .filter(Boolean)
            .map((x) => (x.includes("/") ? x : x === "127.0.0.1" ? "127.0.0.1/32" : x))
        );
      const e = norm(esperado);
      const o = norm(obtido);
      for (const faixa of e) {
        if (!o.has(faixa) && !(faixa === "127.0.0.1/32" && o.has("127.0.0.1"))) return false;
      }
      return true;
    },
  },
  KONG_REAL_IP_RECURSIVE: {
    porque: "sem isto a cadeia de proxies não é percorrida e o IP real fica escondido",
    aceita: (esperado, obtido) => esperado !== "on" || obtido === "on",
  },
};

/**
 * Tira as `KONG_*` de um compose, inclusive as COMENTADAS.
 *
 * Ler linha comentada é de propósito: quando o Kong local é desligado o bloco
 * inteiro vira comentário, e sem isto o projeto migrado sairia da conferência
 * exatamente quando ela passa a importar mais.
 */
function envDoCompose(texto) {
  const env = {};
  for (const linha of texto.split("\n")) {
    const m = /^\s*#?\s*(KONG_[A-Z_]+):\s*(.+?)\s*$/.exec(linha);
    if (!m) continue;
    env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
  return env;
}

function soKong(linhas) {
  const env = {};
  for (const linha of linhas) {
    const i = linha.indexOf("=");
    if (i > 0 && linha.startsWith("KONG_")) env[linha.slice(0, i)] = linha.slice(i + 1);
  }
  return env;
}

async function envDoContainer(nome) {
  const { stdout } = await exec("docker", [
    "inspect",
    nome,
    "--format",
    "{{range .Config.Env}}{{println .}}{{end}}",
  ]);
  return soKong(stdout.split("\n"));
}

/**
 * O mesmo ambiente, quando o Kong roda como Pod do Kubernetes.
 *
 * ⚠️ `exec ... -- env` lê o ambiente do PROCESSO, e não o que o manifesto
 * declara. É a mesma exigência do caminho do Docker, e é o ponto do guarda
 * inteiro: o que protege é o processo no ar, não o arquivo que descreve a
 * intenção. Já houve caso de os dois divergirem — o `liveflow-kong` declarava
 * três variáveis no compose e rodava sem nenhuma.
 */
async function envDoPod() {
  const partes = KUBECTL.split(/\s+/);
  const { stdout } = await exec(partes[0], [
    ...partes.slice(1),
    "exec",
    "-n",
    NAMESPACE,
    ALVO,
    "--",
    "env",
  ]);
  return soKong(stdout.split("\n"));
}

async function main() {
  // 🐞 O GATEWAY DEIXOU DE SER UM CONTAINER DOCKER.
  //
  // Até 21/08/2026 ele rodava em Docker na estação, como `gateway-kong`. Depois
  // do corte, virou Pod do Kubernetes na VM — e este guarda, que só sabia olhar
  // container, passou a reprovar TODA build do gateway com
  //
  //     ❌ container "gateway-kong" não está no ar
  //
  // ⚠️ A mensagem é honesta e leva para o lugar errado: faz procurar um
  // container caído, quando o Kong estava perfeitamente de pé — só que em
  // outro lugar. É a terceira guarda desta semana que sobreviveu ao mundo que
  // ela descrevia.
  //
  // Agora ele tenta os dois e só reprova se NENHUM responder. Assim funciona na
  // estação (Docker) e na VM (Kubernetes) sem precisar saber onde está.
  let doGateway;
  let origem;
  const tentativas = [];
  try {
    doGateway = await envDoContainer(CONTAINER);
    origem = `container ${CONTAINER}`;
    console.log(`   lendo do container Docker "${CONTAINER}"`);
  } catch (e) {
    tentativas.push(`docker: ${e.message.split("\n")[0]}`);
    try {
      doGateway = await envDoPod();
      origem = `Pod ${NAMESPACE}/${ALVO}`;
      console.log(`   lendo do Pod ${NAMESPACE}/${ALVO}`);
    } catch (e2) {
      tentativas.push(`kubernetes: ${e2.message.split("\n")[0]}`);
      console.error("❌ não achei o Kong no ar — nem container, nem Pod.");
      console.error("   não dá para conferir o que vale de verdade.");
      for (const t of tentativas) console.error(`   ${t}`);
      process.exit(1);
    }
  }

  const problemas = [];
  let conferidas = 0;

  for (const proj of PROJETOS) {
    let texto;
    try {
      texto = await readFile(path.join(WORKSPACE, proj.compose), "utf8");
    } catch {
      problemas.push(`${proj.id}: não achei ${proj.compose}`);
      continue;
    }
    const doProjeto = envDoCompose(texto);

    for (const [chave, regra] of Object.entries(DEFESAS)) {
      const esperado = doProjeto[chave];
      if (esperado === undefined) continue; // o projeto não pedia
      const obtido = doGateway[chave];
      conferidas++;
      if (obtido === undefined) {
        problemas.push(`${proj.id}: o gateway NÃO tem ${chave} (o projeto pedia "${esperado}") — ${regra.porque}`);
      } else if (!regra.aceita(esperado, obtido)) {
        problemas.push(`${proj.id}: ${chave} mais fraco no gateway — projeto "${esperado}", gateway "${obtido}"`);
      }
    }
  }

  if (problemas.length) {
    console.error(`❌ ${problemas.length} defesa(s) de ambiente perdida(s) na migração:`);
    for (const p of problemas) console.error("   • " + p);
    process.exit(1);
  }

  console.log(`✅ ${conferidas} defesas de ambiente conferidas contra o ${origem} RODANDO`);
  console.log(`   nenhum projeto migrado ficou com defesa mais fraca do que tinha`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

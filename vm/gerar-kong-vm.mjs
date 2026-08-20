// ===========================================================================
// Converte o `kong/kong.yml` da estação no `vm/kong.yml`, que roda DENTRO do
// cluster da máquina remota.
//
//     node vm/gerar-kong-vm.mjs
//
// ---------------------------------------------------------------------------
// POR QUE CONVERTER, E NÃO ESCREVER OUTRO
// ---------------------------------------------------------------------------
// O `kong.yml` da estação é gerado por `scripts/gerar-kong.mjs` a partir do
// arquivo de cada projeto, e é ele que impede a configuração de divergir.
// Escrever um segundo à mão criaria dois lugares para a mesma verdade — e um
// dia eles discordariam, com o sintoma "funciona num gateway e some no outro".
//
// Este script LÊ o gerado e troca só os DESTINOS: nome de contêiner Docker
// passa a ser nome de Service do Kubernetes.
//
// ---------------------------------------------------------------------------
// 🐞 POR QUE O KONG NÃO RODA EM DOCKER NA VM
// ---------------------------------------------------------------------------
// A primeira versão subia o Kong em Docker ao lado do MicroK8s. Medido em
// 20/08/2026:
//
//     07:17:17  docker compose up -> cria a rede vm_default
//     07:17:22  systemd: Stopping snap.microk8s.daemon-kubelite
//
// Quatro segundos. O MicroK8s vigia mudanças de interface (precisa disso para
// reemitir certificado quando o IP muda) e uma ponte nova do Docker dispara a
// detecção. TODOS os Pods reiniciaram.
//
// Ou seja: cada `docker compose up` derrubaria o cluster. Para um gateway de
// produção isso é inaceitável — reiniciar o gateway reiniciaria as aplicações
// atrás dele.
//
// Dentro do cluster o problema some, e de quebra o Kong passa a falar DIRETO
// com os Services: um salto a menos que pelo Traefik, e sem depender de
// `preserve_host` para o roteamento funcionar.
//
// ---------------------------------------------------------------------------
// ⚠️ O QUE ACONTECE COM UM PROJETO NÃO MIGRADO
// ---------------------------------------------------------------------------
// O script FALHA se encontrar um destino sem correspondência na tabela. É
// deliberado: um destino não traduzido viraria `502` em produção, e o momento
// de descobrir isso é agora, não no corte.
// ===========================================================================
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import YAML from "yaml";

const AQUI = dirname(fileURLToPath(import.meta.url));
const RAIZ = join(AQUI, "..");

const ORIGEM = join(RAIZ, "kong", "kong.yml");
const DESTINO = join(AQUI, "kong.yml");

// ---------------------------------------------------------------------------
// De onde para onde.
//
// A chave é o destino no `kong.yml` da estação; o valor é o Service do cluster.
// Nomes completos (`.svc.cluster.local`) de propósito: o Kong roda no namespace
// `gateway`, então nome curto não resolveria para outro namespace.
// ---------------------------------------------------------------------------
const MAPA = {
  "http://host.docker.internal:3100": "http://urupix-app.urupix.svc.cluster.local:3100",
  "http://host.docker.internal:3200": "http://sigma-financeiro.sigma-financeiro.svc.cluster.local:3200",
  "http://plataforma-app:8080":       "http://plataforma-app.plataforma.svc.cluster.local:8080",
  "http://motor:3300":                "http://central-motor.central-ia.svc.cluster.local:3300",
  // ⚠️ 3000, e não 3301: o Service do portal expõe 3000 e aponta para a porta
  // 3301 do contêiner. Quem chama fala com a porta do SERVICE.
  "http://portal:3301":               "http://central-portal.central-ia.svc.cluster.local:3000",
  "http://sigma-midia:3400":          "http://sigma-midia.sigma-midia.svc.cluster.local:3400",
  "http://sigma-midia-portal:80":     "http://sigma-midia-portal.sigma-midia.svc.cluster.local:80",
};

// Destinos que ainda NÃO têm para onde ir, e por quê. Sem esta lista o script
// falharia; com ela, ele avisa alto e segue — mas deixa o registro de que
// aquelas rotas vão dar 502 até o projeto migrar.
const PENDENTES = {
  "http://sigma-payments-app:8080":
    "sigma-payments ainda nao foi migrado para o cluster",
};

const doc = YAML.parse(readFileSync(ORIGEM, "utf8"));

let trocados = 0;
const naoMapeados = new Map();
const pendentesVistos = new Set();

for (const s of doc.services ?? []) {
  if (!s.url) continue;
  if (MAPA[s.url]) {
    s.url = MAPA[s.url];
    trocados++;
  } else if (PENDENTES[s.url]) {
    pendentesVistos.add(s.url);
  } else {
    naoMapeados.set(s.url, (naoMapeados.get(s.url) ?? 0) + 1);
  }
}

if (naoMapeados.size) {
  console.error("✗ destinos SEM correspondencia na tabela:");
  for (const [u, n] of naoMapeados) console.error(`    ${u}  (${n} service(s))`);
  console.error("  Acrescente em MAPA ou em PENDENTES. Destino nao traduzido vira 502.");
  process.exit(1);
}

const cabecalho = [
  "# GERADO por vm/gerar-kong-vm.mjs a partir de ../kong/kong.yml — NAO editar.",
  "#",
  "# Este e o Kong que roda DENTRO do cluster da maquina remota. A unica",
  "# diferenca para o da estacao e o destino de cada service: nome de container",
  "# Docker virou nome de Service do Kubernetes.",
  "#",
  "# Para mudar uma rota, mude no kong.yml do PROJETO, rode scripts/gerar-kong.mjs",
  "# e depois este. Editar aqui faz a mudanca sumir na proxima geracao.",
  "",
].join("\n");

writeFileSync(DESTINO, cabecalho + YAML.stringify(doc), "utf8");

console.log("✅ vm/kong.yml gerado");
console.log(`   ${trocados} destinos traduzidos para Services do cluster`);
for (const u of pendentesVistos) {
  console.log(`   ⚠️  ${u}`);
  console.log(`       ${PENDENTES[u]} — as rotas dele vao dar 502 ate a migracao`);
}

// Conferencia final. Falhar aqui e melhor que falhar no corte.
const relido = YAML.parse(readFileSync(DESTINO, "utf8"));
let erros = 0;
for (const s of relido.services ?? []) {
  if (!s.url) continue;
  const ok = Object.values(MAPA).includes(s.url) || s.url in PENDENTES;
  if (!ok) { console.error(`   ✗ service ${s.name} ficou com destino ${s.url}`); erros++; }
}
if (erros) { console.error(`   ${erros} problema(s) — NAO use este arquivo`); process.exit(1); }
console.log("   conferido: YAML valido, todo destino aponta para o cluster");

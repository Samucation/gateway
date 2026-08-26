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
  // ⚠️ `estacao`, e não um namespace do projeto: o 4saas ainda NÃO está no
  // cluster. Ele roda na estação (8092), e `quatrosaas.estacao` é um Service
  // sem seletor apontando para o IP de LAN dela.
  //
  // Motivo de não estar no cluster: a VM do WSL está com 25 de 31 GB usados, e
  // subir API + Postgres + Keycloak nesse aperto já derrubou esta distro antes.
  // Quando houver folga, o destino vira `quatrosaas.quatrosaas.svc...` e só
  // esta linha muda.
  "http://quatrosaas:8092":           "http://quatrosaas.estacao.svc.cluster.local:8092",
};

// Destinos que ainda NÃO têm para onde ir, e por quê. Sem esta lista o script
// falharia; com ela, ele avisa alto e segue — mas deixa o registro de que
// aquelas rotas vão dar 502 até o projeto migrar.
const PENDENTES = {
  "http://sigma-payments-app:8080":
    "sigma-payments ainda nao foi migrado para o cluster",
};

// ---------------------------------------------------------------------------
// 🐞 SERVIÇO CUJO DESTINO DEPENDE DO HOST
// ---------------------------------------------------------------------------
// `plataforma-web` atende DOIS domínios apontando para um destino só. Isso era
// verdade quando havia um app: `opuschat` era o nome de produto e `cafe-api` o
// histórico, ambos servidos pelo mesmo processo.
//
// Não é mais. Hoje são dois Deployments, de dois repositórios, com IMAGENS
// diferentes:
//
//     opuschat/opuschat-app       localhost:32000/opuschat:...
//     plataforma/plataforma-app   localhost:32000/plataforma:...
//
// ⚠️ Traduzir os dois hosts para `plataforma-app` faria o Kong servir o produto
// ERRADO em `opuschat.cursodetecnologia.dev.br`. E os dois respondem 200 — ou
// seja, toda conferência por código HTTP passaria, inclusive a do estágio
// "Verificar rotas". O sintoma seria "o site do OpusChat virou outro site",
// sem um único erro em lugar nenhum.
//
// Aqui o host é PARTIDO para fora: ganha uma cópia de cada serviço que o
// atende, com as mesmas rotas e os mesmos plugins, apontando para o seu
// Deployment.
//
// 🐞 A primeira versão indexava por SERVIÇO (`plataforma-web`) e só partia
// aquele. A conferência de dono duplo mostrou que o host também aparece em
// `plataforma-api` e `plataforma-webhooks` — três serviços, e eu tinha tratado
// um. Os outros dois continuariam entregando o app errado, e como todos
// respondem 200, nada apontaria para isso. Indexar por HOST não tem como
// esquecer um serviço: quem procura é o código.
const PARTIR_POR_HOST = {
  "opuschat.cursodetecnologia.dev.br": {
    sufixo: "opuschat",
    url: "http://opuschat-app.opuschat.svc.cluster.local:8080",
  },
};

// ---------------------------------------------------------------------------
// O QUE FAZER COM HOST QUE O KONG NÃO CONHECE
// ---------------------------------------------------------------------------
// O `kong.yml` cobre seis projetos. O cluster atende mais que isso — veltrixa
// (três domínios), sprinklegames (dois), `sigma-midia-arquivos`, `sonar.hmg` —
// por Ingress do Traefik, sem passar por gateway nenhum.
//
// ⚠️ Sem esta rota, pôr o Kong na entrada devolveria 404 nesses domínios: eles
// não sumiriam do cluster, só deixariam de ter quem os encaminhasse. Seis
// domínios de pé viram seis fora do ar de uma vez.
//
// A rota é a MENOS específica possível (sem `hosts`, caminho `/`), então
// qualquer rota declarada ganha dela — e quem não é declarado continua sendo
// atendido exatamente como hoje, pelo Traefik.
//
// Ela NÃO leva plugin de propósito: é passagem, não porta. `cors` sem lista de
// origens aqui liberaria `*` para todo domínio que caísse neste caminho.
const RESERVA = {
  name: "traefik-reserva",
  url: "http://traefik.kube-system.svc.cluster.local:80",
  retries: 0,
  routes: [
    {
      name: "traefik-reserva-tudo",
      paths: ["/"],
      strip_path: false,
      // ⚠️ obrigatório: o Traefik roteia POR HOST. Sem preservar, ele receberia
      // `Host: traefik.kube-system...` e devolveria 404 em tudo.
      preserve_host: true,
    },
  ],
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

// --- partir os hosts cujo destino no cluster é outro -----------------------
const partidos = [];
for (const [host, destino] of Object.entries(PARTIR_POR_HOST)) {
  // Varre TODOS os serviços: o host pode ser atendido por vários.
  const donos = (doc.services ?? []).filter((s) =>
    (s.routes ?? []).some((r) => (r.hosts ?? []).includes(host)));

  if (!donos.length) {
    console.error(`✗ PARTIR_POR_HOST cita "${host}", que nenhuma rota atende`);
    console.error("  O kong.yml mudou de forma. Conferir antes de publicar.");
    process.exit(1);
  }

  const copias = [];
  for (const servico of donos) {
    // A cópia leva as MESMAS rotas e os MESMOS plugins — só muda o destino e o
    // conjunto de hosts. Nome de rota e de service sao unicos no Kong, dai o
    // sufixo: repetir nome faz o Kong recusar a configuracao inteira na partida.
    const copia = JSON.parse(JSON.stringify(servico));
    copia.name = `${servico.name}-${destino.sufixo}`;
    copia.url = destino.url;
    copia.routes = (servico.routes ?? [])
      .filter((r) => (r.hosts ?? []).includes(host))
      .map((r) => {
        const rc = JSON.parse(JSON.stringify(r));
        rc.name = `${r.name}-${destino.sufixo}`;
        rc.hosts = [host];
        return rc;
      });
    copias.push(copia);
    partidos.push({ de: servico.name, para: copia.name, host, url: destino.url });

    // E o host sai do serviço original: deixar nos dois faz o Kong escolher um
    // deles por ordem de carga — e a escolha muda entre partidas.
    servico.routes = (servico.routes ?? [])
      .map((r) => {
        if (!(r.hosts ?? []).includes(host)) return r;
        r.hosts = r.hosts.filter((h) => h !== host);
        return r;
      })
      .filter((r) => (r.hosts ?? []).length > 0);
  }
  doc.services.push(...copias);
}

// Serviço que ficou sem rota nenhuma não tem mais o que fazer.
doc.services = (doc.services ?? []).filter((s) => (s.routes ?? []).length > 0);

// --- a rota de reserva, sempre por último ----------------------------------
doc.services.push(JSON.parse(JSON.stringify(RESERVA)));

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
for (const p of partidos) {
  console.log(`   ↪ ${p.host} saiu de "${p.de}" e foi para "${p.para}"`);
  console.log(`       ${p.url}`);
}
console.log(`   ↪ reserva: host nao declarado segue para o Traefik (${RESERVA.url})`);
for (const u of pendentesVistos) {
  console.log(`   ⚠️  ${u}`);
  console.log(`       ${PENDENTES[u]} — as rotas dele vao dar 502 ate a migracao`);
}

// Conferencia final. Falhar aqui e melhor que falhar no corte.
const relido = YAML.parse(readFileSync(DESTINO, "utf8"));
const PERMITIDOS = new Set([
  ...Object.values(MAPA),
  RESERVA.url,
  ...partidos.map((p) => p.url),
]);
let erros = 0;
for (const s of relido.services ?? []) {
  if (!s.url) continue;
  const ok = PERMITIDOS.has(s.url) || s.url in PENDENTES;
  if (!ok) { console.error(`   ✗ service ${s.name} ficou com destino ${s.url}`); erros++; }
}

// Nome repetido faz o Kong recusar a configuracao INTEIRA na partida, e a
// mensagem fala do nome — nao de qual dos dois esta sobrando.
//
// ⚠️ Service e route sao ESPACOS SEPARADOS: existe service `central-saude` com
// rota `central-saude`, e isso e valido. Conferir os dois juntos reprovava
// configuracao boa — foi o que a primeira versao desta guarda fez.
for (const [tipo, nomes] of [
  ["service", (relido.services ?? []).map((s) => s.name)],
  ["route", (relido.services ?? []).flatMap((s) => (s.routes ?? []).map((r) => r.name))],
]) {
  const vistos = new Set();
  for (const nome of nomes) {
    if (!nome) continue;
    if (vistos.has(nome)) { console.error(`   ✗ ${tipo} com nome repetido: ${nome}`); erros++; }
    vistos.add(nome);
  }
}

// ⚠️ O host partido só pode aparecer nas CÓPIAS. Se ficou também no serviço de
// origem, o Kong tem dois candidatos para a mesma requisição e escolhe por
// ordem de carga — o domínio passa a servir um app ou outro conforme a partida.
for (const host of Object.keys(PARTIR_POR_HOST)) {
  const permitidos = new Set(partidos.filter((p) => p.host === host).map((p) => p.para));
  const estranhos = (relido.services ?? [])
    .filter((s) => (s.routes ?? []).some((r) => (r.hosts ?? []).includes(host)))
    .map((s) => s.name)
    .filter((n) => !permitidos.has(n));
  if (estranhos.length) {
    console.error(`   ✗ ${host} ainda aparece em: ${estranhos.join(", ")}`);
    erros++;
  }
}

if (erros) { console.error(`   ${erros} problema(s) — NAO use este arquivo`); process.exit(1); }
console.log("   conferido: YAML valido, destinos no cluster, nomes unicos, hosts sem dono duplo");

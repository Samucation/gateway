// CONSOLE DO GATEWAY — o backend que a tela usa para editar a configuração.
//
//     node console/servidor.mjs        (a partir da raiz do projeto gateway)
//
// ---------------------------------------------------------------------------
// POR QUE EXISTE UM BACKEND
// ---------------------------------------------------------------------------
// A tela não escreve em disco nem roda container. Tudo que muda configuração
// passa por aqui — e é aqui que mora a proteção, porque uma config errada neste
// gateway derruba os CINCO projetos de uma vez.
//
// ---------------------------------------------------------------------------
// A REGRA QUE O CONSOLE NÃO PODE QUEBRAR
// ---------------------------------------------------------------------------
// `kong/kong.yml` é GERADO. Editar o gerado faz a mudança sumir na próxima vez
// que alguém rodar `npm run gerar` — calada, e semanas depois.
//
// Por isso o console edita o `kong.yml` DO PROJETO DE ORIGEM e regera. É mais
// trabalho e é o único jeito que não briga com o gerador.
//
// Pelo mesmo motivo NÃO se usa `POST /config` da Admin API: ele substitui a
// configuração viva sem tocar em arquivo nenhum, e o resultado é um gateway
// rodando algo que não está escrito em lugar nenhum.
//
// ---------------------------------------------------------------------------
// APLICAR É UMA TRANSAÇÃO
// ---------------------------------------------------------------------------
// Gravar o arquivo NÃO muda nada sozinho. Só `POST /api/aplicar` mexe no
// gateway, e ele faz tudo ou desfaz tudo:
//
//   1. guarda cópia de todos os kong.yml e do gerado
//   2. roda o gerador
//   3. `kong config parse`  — recusa YAML que o Kong não aceita
//   4. `conferir-plugins`   — nenhuma defesa a menos que o Kong de origem
//   5. `conferir-ambiente`  — nenhuma variável de defesa perdida
//   6. `kong reload`        — 400 ms, sem derrubar conexão (medido)
//   7. confere que os hosts conhecidos ainda respondem
//
// Qualquer passo que falhe restaura as cópias, regera e recarrega. O passo 7
// existe porque os anteriores olham para arquivo: só ele prova que o gateway
// que está no ar atende de verdade.
import { createServer, request as httpRequest } from "node:http";
import { readFile, writeFile, mkdir, appendFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { promisify } from "node:util";
import path from "node:path";
import { parse } from "yaml";

const exec = promisify(execFile);

const RAIZ = path.resolve(path.join(import.meta.dirname, ".."));
const WORKSPACE = path.resolve(path.join(RAIZ, ".."));
const CONTAINER = "gateway-kong";
const ADMIN = "http://127.0.0.1:8051";
const PORTA = Number(process.env.CONSOLE_PORT ?? 8060);

/**
 * Os projetos e o `kong.yml` de cada um.
 *
 * Espelha o PROJETOS de scripts/gerar-kong.mjs de propósito: o console só
 * EDITA arquivo, quem decide host e rota interna continua sendo o gerador.
 * Duplicar a lista aqui é feio; deixar o console inventar host seria pior.
 */
const PROJETOS = [
  { id: "liveflow", nome: "Urupix / live-flow", config: "live-flow/deploy/kong/kong.yml" },
  { id: "sigmafin", nome: "Sigma Financeiro", config: "sigma-financeiro/deploy/kong/kong.yml" },
  { id: "plataforma", nome: "Plataforma de Atendimento", config: "cafe-mobile-erp/kong/kong.yml" },
  { id: "central", nome: "Central de IA", config: "central-ia/deploy/kong/kong.yml" },
  { id: "sigmapay", nome: "Sigma Payments", config: "sigma-payments/infra/kong/kong.yml" },
];

/** Hosts que têm que continuar respondendo depois de aplicar. */
const HOSTS_DE_PROVA = [
  "urupix.com.br",
  "sigma-financeiro.cursodetecnologia.dev.br",
  "cafe-api.cursodetecnologia.dev.br",
  "central.interno",
];

const caminhoDe = (proj) => path.join(WORKSPACE, proj.config);
const digest = (texto) => createHash("sha256").update(texto).digest("hex").slice(0, 16);

async function rodar(cmd, args, opts = {}) {
  try {
    const { stdout, stderr } = await exec(cmd, args, { cwd: RAIZ, maxBuffer: 8 * 1024 * 1024, ...opts });
    return { ok: true, saida: (stdout || "") + (stderr || "") };
  } catch (e) {
    return { ok: false, saida: (e.stdout || "") + (e.stderr || "") || String(e) };
  }
}

// ---------------------------------------------------------------------------
// leitura
// ---------------------------------------------------------------------------

async function resumoDoProjeto(proj) {
  let texto;
  try {
    texto = await readFile(caminhoDe(proj), "utf8");
  } catch {
    return { ...proj, existe: false };
  }
  let doc;
  try {
    doc = parse(texto);
  } catch (e) {
    return { ...proj, existe: true, erro: String(e.message ?? e) };
  }
  const services = (doc.services ?? []).map((s) => ({
    nome: s.name,
    upstream: s.url ?? "",
    rotas: (s.routes ?? []).map((r) => ({
      nome: r.name,
      caminhos: r.paths ?? [],
      metodos: r.methods ?? [],
      plugins: (r.plugins ?? []).map((p) => p.name),
    })),
    plugins: (s.plugins ?? []).map((p) => p.name),
  }));
  return {
    ...proj,
    existe: true,
    sha: digest(texto),
    services,
    pluginsDeTopo: (doc.plugins ?? []).map((p) => ({
      nome: p.name,
      escopo: p.route ? `rota ${p.route}` : p.service ? `serviço ${p.service}` : "projeto inteiro",
    })),
  };
}

async function estadoDoGateway() {
  const [status, insp] = await Promise.all([
    fetch("http://127.0.0.1:8150/status", { signal: AbortSignal.timeout(5000) })
      .then((r) => (r.ok ? r.json() : null))
      .catch(() => null),
    rodar("docker", [
      "inspect",
      CONTAINER,
      "--format",
      "{{.State.Status}}|{{.State.Health.Status}}|{{.RestartCount}}|{{.State.StartedAt}}",
    ]),
  ]);
  const [estado, saude, reinicios, desde] = (insp.saida || "").trim().split("|");
  return { noAr: !!status, conexoes: status?.server ?? null, estado, saude, reinicios, desde };
}

// ---------------------------------------------------------------------------
// tráfego e abuso
// ---------------------------------------------------------------------------

/**
 * Limites que separam "movimento" de "alguém tentando alguma coisa".
 *
 * São por JANELA (o padrão é 15 min), não por minuto: rajada curta é normal —
 * uma página abre dezenas de pedidos de uma vez. O que denuncia abuso é o
 * volume sustentado, ou a proporção de tentativas que dão errado.
 */
const SINAIS = {
  requisicoesPorIp: 900, // ~1/s sustentado: acima disso não é gente navegando
  bloqueiosPorIp: 20, // já bateu no teto muitas vezes e continua tentando
  errosDeAutenticacao: 30, // 401/403 em série é varredura de credencial
  naoEncontradosPorIp: 60, // 404 em série é varredura de caminho
};

/**
 * Host → aplicação. É o que o formato de log novo permite responder: sem isto,
 * um `GET /` não diz se foi o Urupix, o Sigma ou o cafe — os cinco usam os
 * mesmos caminhos, que é justamente o motivo de a unificação exigir `hosts:`.
 */
const APP_POR_HOST = {
  "urupix.com.br": "liveflow",
  "www.urupix.com.br": "liveflow",
  "urupix.cursodetecnologia.dev.br": "liveflow",
  "urupix.interno": "liveflow",
  "sigma-financeiro.cursodetecnologia.dev.br": "sigmafin",
  "sigma.interno": "sigmafin",
  "cafe-api.cursodetecnologia.dev.br": "plataforma",
  "cafe.interno": "plataforma",
  "central.interno": "central",
  "sigma-payments.interno": "sigmapay",
};
const NOME_DA_APP = Object.fromEntries(PROJETOS.map((p) => [p.id, p.nome]));

/** Onde o histórico sobrevive ao container e à rotação do log do docker. */
const DADOS = path.join(import.meta.dirname, "dados");
const ARQ_INCIDENTES = path.join(DADOS, "incidentes.jsonl");
const ARQ_AMOSTRAS = path.join(DADOS, "amostras.jsonl");

async function anexar(arquivo, obj) {
  await mkdir(DADOS, { recursive: true });
  await appendFile(arquivo, JSON.stringify(obj) + "\n", "utf8");
}

async function lerJsonl(arquivo, limite = 5000) {
  try {
    const texto = await readFile(arquivo, "utf8");
    const linhas = texto.trim().split("\n").filter(Boolean).slice(-limite);
    return linhas.map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  } catch {
    return [];
  }
}

/**
 * Converte "14/Aug/2026:18:21:30 +0000" em Date.
 *
 * O nginx escreve o mês em inglês abreviado, e `new Date()` não lê esse
 * formato — sem a tabela, toda linha viraria data inválida e o gráfico ficaria
 * vazio sem erro nenhum.
 */
const MESES = { Jan:0,Feb:1,Mar:2,Apr:3,May:4,Jun:5,Jul:6,Aug:7,Sep:8,Oct:9,Nov:10,Dec:11 };
function quandoParaData(s) {
  const m = /^(\d{2})\/(\w{3})\/(\d{4}):(\d{2}):(\d{2}):(\d{2})/.exec(s);
  if (!m) return null;
  return new Date(Date.UTC(+m[3], MESES[m[2]] ?? 0, +m[1], +m[4], +m[5], +m[6]));
}

/**
 * Lê o log de acesso do Kong.
 *
 * É a única fonte que tem o IP do cliente E o host: as métricas do Prometheus
 * agregam por rota e status e não sabem QUEM pediu — servem para o gráfico, não
 * para achar o abusador.
 */
async function trafego(minutos = 15, filtro = {}) {
  const { saida } = await rodar("docker", ["logs", CONTAINER, "--since", `${minutos}m`], { cwd: RAIZ });

  const porIp = new Map();
  const porStatus = new Map();
  const porRota = new Map();
  const porMinuto = new Map();
  const porApp = new Map();
  let total = 0;
  let ignoradas = 0;

  for (const linha of saida.split("\n")) {
    const campos = linha.split("|");
    // 9 campos = formato novo. Linha antiga (de antes da troca) não tem host e
    // é descartada de propósito: misturar os dois formatos daria número certo
    // no total e errado por aplicação, que é pior do que faltar dado.
    if (campos.length < 9) { if (linha.trim()) ignoradas++; continue; }
    const [ip, host, quando, metodo, caminho, statusTexto, bytes, dur] = campos;
    const status = Number(statusTexto);
    if (!Number.isFinite(status)) { ignoradas++; continue; }

    const app = APP_POR_HOST[host] ?? "desconhecido";

    if (filtro.app && app !== filtro.app) continue;
    if (filtro.ip && ip !== filtro.ip) continue;
    if (filtro.status && String(status) !== String(filtro.status)) continue;
    if (filtro.caminho && !caminho.includes(filtro.caminho)) continue;
    total++;

    const atual = porIp.get(ip) ?? { ip, total: 0, bloqueadas: 0, semAutorizacao: 0, naoEncontradas: 0, apps: new Set(), caminhos: new Set() };
    atual.total++;
    if (status === 429) atual.bloqueadas++;
    if (status === 401 || status === 403) atual.semAutorizacao++;
    if (status === 404) atual.naoEncontradas++;
    atual.apps.add(app);
    if (atual.caminhos.size < 12) atual.caminhos.add(`${metodo} ${caminho}`);
    porIp.set(ip, atual);

    porStatus.set(status, (porStatus.get(status) ?? 0) + 1);
    porRota.set(caminho, (porRota.get(caminho) ?? 0) + 1);

    const a = porApp.get(app) ?? { app, nome: NOME_DA_APP[app] ?? app, total: 0, bloqueadas: 0, erros: 0, bytes: 0, duracao: 0 };
    a.total++;
    if (status === 429) a.bloqueadas++;
    if (status >= 500) a.erros++;
    a.bytes += Number(bytes) || 0;
    a.duracao += Number(dur) || 0;
    porApp.set(app, a);

    const minuto = quando.slice(0, 17);
    const balde = porMinuto.get(minuto) ?? { minuto, total: 0, bloqueadas: 0 };
    balde.total++;
    if (status === 429) balde.bloqueadas++;
    porMinuto.set(minuto, balde);
  }

  const ips = [...porIp.values()]
    .map((x) => ({ ...x, apps: [...x.apps], caminhos: [...x.caminhos] }))
    .sort((a, b) => b.total - a.total);

  const alertas = [];
  for (const x of ips) {
    if (x.total >= SINAIS.requisicoesPorIp)
      alertas.push({ nivel: "alto", ip: x.ip, apps: x.apps, texto: `${x.total} requisições em ${minutos} min` });
    if (x.bloqueadas >= SINAIS.bloqueiosPorIp)
      alertas.push({ nivel: "alto", ip: x.ip, apps: x.apps, texto: `levou ${x.bloqueadas} bloqueios (429) e continuou` });
    if (x.semAutorizacao >= SINAIS.errosDeAutenticacao)
      alertas.push({ nivel: "alto", ip: x.ip, apps: x.apps, texto: `${x.semAutorizacao} respostas 401/403 — varredura de credencial` });
    if (x.naoEncontradas >= SINAIS.naoEncontradosPorIp)
      alertas.push({ nivel: "medio", ip: x.ip, apps: x.apps, texto: `${x.naoEncontradas} respostas 404 — varredura de caminho` });
  }

  const apps = [...porApp.values()]
    .map((a) => ({ ...a, mediaMs: a.total ? Math.round((a.duracao / a.total) * 1000) : 0 }))
    .sort((a, b) => b.total - a.total);

  return {
    minutos, total, ignoradas,
    bloqueadas: porStatus.get(429) ?? 0,
    serie: [...porMinuto.values()].sort((a, b) => a.minuto.localeCompare(b.minuto)),
    ips: ips.slice(0, 25),
    apps,
    porStatus: Object.fromEntries([...porStatus.entries()].sort((a, b) => b[1] - a[1])),
    porRota: Object.fromEntries([...porRota.entries()].sort((a, b) => b[1] - a[1]).slice(0, 15)),
    alertas, sinais: SINAIS,
  };
}

// ---------------------------------------------------------------------------
// aplicar — a transação
// ---------------------------------------------------------------------------

// O instantâneo do último estado que FUNCIONOU. Gravado só depois de um
// aplicar inteiro bem-sucedido.
const ULTIMO_BOM = path.join(import.meta.dirname, ".ultimo-bom");

/**
 * 🐞 A primeira versão copiava os arquivos no INÍCIO do `aplicar()` — ou seja,
 * depois de a tela já ter gravado a edição. A "cópia de segurança" guardava o
 * estado RUIM, e o rollback restaurava fielmente o defeito.
 *
 * Foi pego plantando um plugin inexistente: o `kong config parse` recusou, o
 * rollback rodou e disse ✅, e o arquivo continuou quebrado — o pior desfecho
 * possível, porque o relatório afirmava que estava tudo desfeito.
 *
 * O que serve de rede é o último estado que PASSOU pelas verificações, não o
 * que estava em disco um segundo antes.
 */
async function gravarUltimoBom() {
  await mkdir(ULTIMO_BOM, { recursive: true });
  for (const proj of PROJETOS) {
    try {
      await writeFile(path.join(ULTIMO_BOM, `${proj.id}.yml`), await readFile(caminhoDe(proj), "utf8"));
    } catch {
      /* projeto sem arquivo */
    }
  }
}

async function restaurarUltimoBom(passos) {
  let restaurados = 0;
  for (const proj of PROJETOS) {
    try {
      const bom = await readFile(path.join(ULTIMO_BOM, `${proj.id}.yml`), "utf8");
      const atual = await readFile(caminhoDe(proj), "utf8").catch(() => null);
      if (atual !== bom) {
        await writeFile(caminhoDe(proj), bom);
        restaurados++;
      }
    } catch {
      /* sem instantâneo desse projeto */
    }
  }

  if (!restaurados) {
    passos.push({
      nome: "ROLLBACK",
      ok: true,
      saida:
        "nada a restaurar: ou nenhum arquivo mudou, ou ainda não existe um instantâneo bom " +
        "(ele nasce no primeiro APLICAR que passa inteiro).",
    });
    return;
  }

  await rodar("node", ["scripts/gerar-kong.mjs"]);
  const r = await rodar("docker", ["exec", CONTAINER, "kong", "reload"]);
  const prova = await hostsRespondem();
  passos.push({
    nome: `ROLLBACK — ${restaurados} arquivo(s) voltaram ao último estado bom`,
    ok: r.ok && prova.ok,
    saida: (r.saida + "\n" + prova.saida).trim(),
  });
}

/**
 * Bate no gateway fingindo ser cada domínio.
 *
 * 🐞 `fetch` NÃO serve aqui: o `Host` é header proibido no undici e some da
 * requisição sem aviso. A prova então chegava sem Host, nenhuma rota casava, e
 * as quatro davam 404 — a transação desfazia edição BOA achando que tinha
 * quebrado o ambiente. Um alarme falso que bloqueia tudo é tão ruim quanto não
 * ter verificação. `node:http` deixa mandar o Host.
 */
function pedirComHost(host) {
  return new Promise((resolve) => {
    const req = httpRequest(
      { host: "127.0.0.1", port: 8050, path: "/", method: "GET", headers: { Host: host }, timeout: 12000 },
      (res) => {
        res.resume();
        resolve(res.statusCode);
      }
    );
    req.on("timeout", () => { req.destroy(); resolve(0); });
    req.on("error", () => resolve(0));
    req.end();
  });
}

async function hostsRespondem() {
  const linhas = [];
  let todosOk = true;
  for (const host of HOSTS_DE_PROVA) {
    const cod = await pedirComHost(host);
    // 404 aqui significa "nenhuma rota casou este host" — que é exatamente o
    // estrago que uma edição errada causa, e passa despercebido sem esta prova
    const ok = cod > 0 && cod !== 404;
    todosOk &&= ok;
    linhas.push(`${ok ? "ok" : "FALHOU"} ${host} → ${cod || "sem resposta"}`);
  }
  return { ok: todosOk, saida: linhas.join("\n") };
}

async function aplicar() {
  const passos = [];

  const etapas = [
    ["gerar a config unificada", () => rodar("node", ["scripts/gerar-kong.mjs"])],
    [
      "o Kong aceita o YAML?",
      () =>
        rodar("docker", [
          "run", "--rm", "-e", "KONG_DATABASE=off",
          "-v", `${path.join(RAIZ, "kong")}:/kong:ro`,
          "kong:3.8", "kong", "config", "parse", "/kong/kong.yml",
        ]),
    ],
    ["nenhum plugin a menos", () => rodar("node", ["scripts/conferir-plugins.mjs"])],
    ["nenhuma defesa de ambiente a menos", () => rodar("node", ["scripts/conferir-ambiente.mjs"])],
    ["recarregar o gateway", () => rodar("docker", ["exec", CONTAINER, "kong", "reload"])],
    ["os hosts conhecidos respondem?", () => hostsRespondem()],
  ];

  for (const [nome, fn] of etapas) {
    const r = await fn();
    passos.push({ nome, ok: r.ok, saida: (r.saida || "").trim().slice(0, 4000) });
    if (!r.ok) {
      await restaurarUltimoBom(passos);
      return { ok: false, passos };
    }
  }

  // só aqui o estado vira "bom": passou pelo Kong, pelos dois guardas e pela
  // prova de que os hosts respondem
  await gravarUltimoBom();
  passos.push({ nome: "instantâneo do estado bom atualizado", ok: true, saida: "" });
  return { ok: true, passos };
}

// ---------------------------------------------------------------------------
// http
// ---------------------------------------------------------------------------

const json = (res, cod, corpo) => {
  res.writeHead(cod, { "content-type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(corpo));
};

async function corpoDe(req) {
  const pedacos = [];
  for await (const p of req) pedacos.push(p);
  return JSON.parse(Buffer.concat(pedacos).toString("utf8") || "{}");
}

const servidor = createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const rota = url.pathname;

  try {
    if (rota === "/api/estado") return json(res, 200, await estadoDoGateway());

    if (rota === "/api/trafego") {
      const minutos = Math.min(180, Math.max(1, Number(url.searchParams.get("minutos") ?? 15)));
      const filtro = {
        app: url.searchParams.get("app") || null,
        ip: url.searchParams.get("ip") || null,
        status: url.searchParams.get("status") || null,
        caminho: url.searchParams.get("caminho") || null,
      };
      return json(res, 200, await trafego(minutos, filtro));
    }

    // Histórico que sobrevive à rotação do log do docker e à recriação do
    // container — sem isto "relatório de incidentes" seria só a última hora.
    if (rota === "/api/incidentes") {
      const app = url.searchParams.get("app");
      const nivel = url.searchParams.get("nivel");
      const desde = Number(url.searchParams.get("dias") ?? 7) * 86400000;
      const corte = Date.now() - desde;
      let lista = (await lerJsonl(ARQ_INCIDENTES)).filter((i) => Date.parse(i.quando) >= corte);
      if (app) lista = lista.filter((i) => (i.apps ?? []).includes(app));
      if (nivel) lista = lista.filter((i) => i.nivel === nivel);
      return json(res, 200, { total: lista.length, incidentes: lista.reverse().slice(0, 500) });
    }

    if (rota === "/api/amostras") {
      const dias = Number(url.searchParams.get("dias") ?? 2);
      const corte = Date.now() - dias * 86400000;
      const lista = (await lerJsonl(ARQ_AMOSTRAS)).filter((a) => Date.parse(a.quando) >= corte);
      return json(res, 200, { amostras: lista });
    }

    if (rota === "/api/projetos") {
      return json(res, 200, await Promise.all(PROJETOS.map(resumoDoProjeto)));
    }

    const mArquivo = /^\/api\/projetos\/([a-z]+)\/arquivo$/.exec(rota);
    if (mArquivo) {
      const proj = PROJETOS.find((p) => p.id === mArquivo[1]);
      if (!proj) return json(res, 404, { erro: "projeto desconhecido" });

      if (req.method === "GET") {
        const texto = await readFile(caminhoDe(proj), "utf8");
        return json(res, 200, { texto, sha: digest(texto), caminho: proj.config });
      }

      if (req.method === "PUT") {
        const { texto, sha } = await corpoDe(req);
        if (typeof texto !== "string" || !texto.trim()) {
          return json(res, 400, { erro: "texto vazio" });
        }
        // 🐞 Sem esta conferência, dois consoles abertos (ou uma aba velha)
        // sobrescrevem um ao outro em silêncio — e some rota sem ninguém ter
        // apagado nada.
        const atual = await readFile(caminhoDe(proj), "utf8");
        if (sha && sha !== digest(atual)) {
          return json(res, 409, { erro: "o arquivo mudou desde que você abriu — recarregue antes de gravar" });
        }
        try {
          parse(texto); // YAML quebrado nem chega a virar arquivo
        } catch (e) {
          return json(res, 400, { erro: "YAML inválido: " + (e.message ?? e) });
        }
        await writeFile(caminhoDe(proj), texto);
        return json(res, 200, { sha: digest(texto), aviso: "gravado. Nada mudou no gateway até você APLICAR." });
      }
    }

    if (rota === "/api/aplicar" && req.method === "POST") {
      const r = await aplicar();
      return json(res, r.ok ? 200 : 500, r);
    }

    // leitura da Admin API do Kong (DB-less: só GET faz sentido)
    if (rota.startsWith("/api/kong/")) {
      const alvo = ADMIN + "/" + rota.slice("/api/kong/".length) + url.search;
      const r = await fetch(alvo, { signal: AbortSignal.timeout(10000) });
      res.writeHead(r.status, { "content-type": r.headers.get("content-type") ?? "application/json" });
      return res.end(Buffer.from(await r.arrayBuffer()));
    }

    // A tela compilada. `dist/browser` e não `dist`: o Angular 21 separa a
    // saída de navegador da de servidor, e apontar para `dist` devolve 404 em
    // TUDO — inclusive no index, o que parece build quebrado e não é.
    const estaticos = path.join(import.meta.dirname, "ui", "dist", "browser");
    const arquivo = rota === "/" ? "index.html" : rota.slice(1);
    try {
      const dados = await readFile(path.join(estaticos, arquivo));
      const tipo =
        { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".ico": "image/x-icon" }[
          path.extname(arquivo)
        ] ?? "application/octet-stream";
      res.writeHead(200, { "content-type": tipo + "; charset=utf-8" });
      return res.end(dados);
    } catch {
      try {
        const html = await readFile(path.join(estaticos, "index.html"));
        res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
        return res.end(html);
      } catch {
        return json(res, 404, { erro: "a tela ainda não foi compilada — rode `npm run console:ui`" });
      }
    }
  } catch (e) {
    return json(res, 500, { erro: String(e.message ?? e) });
  }
});

// ---------------------------------------------------------------------------
// vigia — avisa mesmo com o console fechado
// ---------------------------------------------------------------------------
//
// O painel só alerta quem está olhando para ele, e ataque não escolhe hora. O
// vigia relê a janela sozinho e manda o que for novo para um webhook.
//
// O canal é uma URL em `GATEWAY_ALERTA_WEBHOOK` de propósito: Telegram, Discord,
// Slack e n8n aceitam POST com JSON, então o console não precisa saber de token
// de nenhum deles nem guardar segredo de outro projeto.
//
//     GATEWAY_ALERTA_WEBHOOK=https://... npm run console

const WEBHOOK = process.env.GATEWAY_ALERTA_WEBHOOK ?? "";
const INTERVALO_VIGIA_MS = 5 * 60 * 1000;

// 🐞 Sem esta memória o vigia repetiria o MESMO alerta a cada cinco minutos
// enquanto o ataque durasse — e aviso que repete demais é aviso que se aprende
// a ignorar, que é pior do que não avisar.
const jaAvisado = new Map();
const LEMBRAR_MS = 60 * 60 * 1000;

async function vigiar() {
  try {
    const t = await trafego(15);
    const agora = Date.now();

    // amostra periódica: é o que permite ver "acessos do mês passado" depois
    // que o log do docker já rodou. Uma linha a cada 5 min, por aplicação.
    await anexar(ARQ_AMOSTRAS, {
      quando: new Date().toISOString(),
      janelaMin: t.minutos,
      total: t.total,
      bloqueadas: t.bloqueadas,
      apps: t.apps.map((a) => ({ app: a.app, total: a.total, bloqueadas: a.bloqueadas, erros: a.erros, mediaMs: a.mediaMs })),
    });

    for (const [chave, quando] of jaAvisado) {
      if (agora - quando > LEMBRAR_MS) jaAvisado.delete(chave);
    }

    const novos = t.alertas.filter((a) => {
      const chave = `${a.ip}|${a.texto.replace(/\d+/g, "#")}`;
      if (jaAvisado.has(chave)) return false;
      jaAvisado.set(chave, agora);
      return true;
    });
    if (!novos.length) return;

    for (const a of novos) {
      console.log(`[alerta ${a.nivel}] ${a.ip} — ${a.texto}`);
      await anexar(ARQ_INCIDENTES, { quando: new Date().toISOString(), ...a });
    }
    if (!WEBHOOK) return;

    const texto =
      `⚠️ Gateway — ${novos.length} sinal(is) de abuso nos últimos 15 min:\n` +
      novos.map((a) => `• ${a.ip}: ${a.texto}`).join("\n");
    await fetch(WEBHOOK, {
      method: "POST",
      headers: { "content-type": "application/json" },
      // `text` e `content` juntos: Slack/n8n leem o primeiro, Discord o segundo.
      // Mandar os dois evita um adaptador por serviço.
      body: JSON.stringify({ text: texto, content: texto, alertas: novos }),
      signal: AbortSignal.timeout(10000),
    }).catch((e) => console.log("falha ao avisar o webhook: " + e.message));
  } catch (e) {
    console.log("vigia falhou nesta rodada: " + (e.message ?? e));
  }
}

setInterval(vigiar, INTERVALO_VIGIA_MS);
setTimeout(vigiar, 20000);

// ⚠️ 127.0.0.1 e não 0.0.0.0. Este serviço edita a configuração do gateway de
// TODOS os projetos e roda comandos docker — quem o alcança manda no ambiente
// inteiro. Se um dia precisar de acesso remoto, é atrás de autenticação de
// verdade, nunca abrindo a porta.
servidor.listen(PORTA, "127.0.0.1", () => {
  console.log(`console do gateway em http://127.0.0.1:${PORTA} (só loopback)`);
});

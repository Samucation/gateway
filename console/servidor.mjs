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
import { readFile, writeFile, mkdir, readdir } from "node:fs/promises";
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

// ⚠️ 127.0.0.1 e não 0.0.0.0. Este serviço edita a configuração do gateway de
// TODOS os projetos e roda comandos docker — quem o alcança manda no ambiente
// inteiro. Se um dia precisar de acesso remoto, é atrás de autenticação de
// verdade, nunca abrindo a porta.
servidor.listen(PORTA, "127.0.0.1", () => {
  console.log(`console do gateway em http://127.0.0.1:${PORTA} (só loopback)`);
});

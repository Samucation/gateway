// CONFERE que nenhuma rota PÚBLICA está sem teto de requisições.
//
//     node scripts/conferir-exposicao.mjs
//
// ---------------------------------------------------------------------------
// POR QUE ESTE SCRIPT EXISTE
// ---------------------------------------------------------------------------
// Os dois guardas anteriores comparam o gateway com o que os projetos JÁ
// tinham. Nenhum dos dois pergunta se o que eles tinham era suficiente — e não
// era: em 14/08/2026 nove rotas estavam sem `rate-limiting`, entre elas
// `/v1/marketing` do cafe-mobile-erp, que exporta a base inteira em CSV e apaga
// cadastro por LGPD.
//
// Sem teto, uma credencial vazada esvazia a base numa tarde, e o log mostra só
// chamadas autenticadas — todas com cara de legítimas. Rate-limit não substitui
// autenticação; ele limita o estrago de quem passou por ela.
//
// Rota interna (só apelido `.interno`) não entra: ela não é alcançável da
// internet, e exigir teto ali seria ruído que ensina a ignorar o guarda.
import { readFile } from "node:fs/promises";
import path from "node:path";
import { parse } from "yaml";

/** Sufixo dos apelidos locais. Host assim não é alcançável de fora. */
const INTERNO = ".interno";

/**
 * Rotas que podem ficar sem teto, com o motivo.
 *
 * Lista curta e nominal de propósito: exceção fácil de adicionar vira guarda
 * que não guarda nada. Cada entrada precisa dizer POR QUE, para a próxima
 * pessoa poder discordar com fundamento.
 */
const LIBERADAS = {
  "plataforma-webhooks-provedores":
    "quem chama é o Telegram e a Meta em rajada; o teto é o do próprio serviço",
};

async function main() {
  const doc = parse(await readFile(path.join("kong", "kong.yml"), "utf8"));
  const globais = (doc.plugins ?? []).map((p) => p.name);

  const desprotegidas = [];
  let publicas = 0;
  let internas = 0;

  for (const s of doc.services ?? []) {
    const doServico = [...globais, ...(s.plugins ?? []).map((p) => p.name)];

    for (const r of s.routes ?? []) {
      const hosts = r.hosts ?? [];
      const soInterna = hosts.length > 0 && hosts.every((h) => String(h).endsWith(INTERNO));
      if (soInterna) {
        internas++;
        continue;
      }
      publicas++;

      const plugins = [...doServico, ...(r.plugins ?? []).map((p) => p.name)];
      // `request-termination` conta como proteção: a rota devolve 404 sem
      // chegar no upstream, então não há o que abusar
      const protegida =
        plugins.includes("rate-limiting") ||
        plugins.includes("request-termination") ||
        plugins.includes("ip-restriction");

      if (!protegida && !LIBERADAS[r.name]) {
        desprotegidas.push(`${r.name}  →  ${(r.paths ?? []).join(" ")}`);
      }
    }
  }

  if (desprotegidas.length) {
    console.error(`❌ ${desprotegidas.length} rota(s) PÚBLICA(s) sem teto de requisições:`);
    for (const r of desprotegidas) console.error("   • " + r);
    console.error("\n   Ponha `rate-limiting` no kong.yml DO PROJETO e rode `npm run gerar`.");
    console.error("   Se a rota realmente não deve ter teto, declare em LIBERADAS com o motivo.");
    process.exit(1);
  }

  console.log(`✅ ${publicas} rotas públicas, todas com teto de requisições`);
  console.log(`   ${internas} rotas internas (só apelido .interno) fora do escopo, como esperado`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

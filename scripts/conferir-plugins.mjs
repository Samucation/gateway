// CONFERE que a config gerada aplica, em cada rota, EXATAMENTE os mesmos
// plugins que o Kong do projeto aplicava.
//
//     node scripts/conferir-plugins.mjs
//
// ---------------------------------------------------------------------------
// POR QUE ESTE SCRIPT EXISTE
// ---------------------------------------------------------------------------
// A primeira versão do gerador descartou 18 plugins: copiou só `services:` e
// trocou o bloco `plugins:` de topo por três globais sem config. Foram embora,
// entre outros, o `ip-restriction` do cafe-mobile-erp e o `X-Frame-Options:
// DENY` da central-ia — e o `cors` global sem `origins` passou a liberar `*`.
//
// A comparação rota a rota por HTTP não pegou nada disso: os 13 caminhos
// responderam o mesmo código E o mesmo corpo, byte a byte. É o que se espera —
// rate-limit não dispara em 13 requisições, ip-restriction não barra o
// localhost, e cabeçalho de resposta não muda o corpo.
//
// Navegar não prova plugin. Só a comparação da config prova.
//
// ---------------------------------------------------------------------------
// COMO O KONG RESOLVE
// ---------------------------------------------------------------------------
// Para uma requisição que casa a rota R do serviço S, cada NOME de plugin é
// aplicado uma vez só, na definição mais específica: rota > serviço > global.
// Então comparar listas soltas não serve — o que vale é o conjunto EFETIVO por
// rota, que é o que este script monta dos dois lados.
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parse } from "yaml";

// A raiz do PROPRIO repositorio -- e nao a pasta acima. Ver a nota na leitura
// de `referencia/` mais abaixo: a base de comparacao mora aqui dentro, para o
// script funcionar tanto na estacao quanto num agente de CI isolado.
// ⚠️ `fileURLToPath`, e nao `new URL(...).pathname`.
//
// No Windows o `pathname` sai como `/E:/Desenvolvimento/...`, com barra
// inicial, e o `path.resolve` seguinte trata isso como caminho relativo --
// produzindo `E:\E:\Desenvolvimento\...` e um ENOENT que parece
// arquivo faltando quando o problema e o caminho.
const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const PROJETOS = [
  { id: "liveflow", config: "live-flow/deploy/kong/kong.yml" },
  { id: "sigmafin", config: "sigma-financeiro/deploy/kong/kong.yml" },
  { id: "plataforma", config: "cafe-mobile-erp/kong/kong.yml" },
  { id: "central", config: "central-ia/deploy/kong/kong.yml" },
  { id: "sigmapay", config: "sigma-payments/infra/kong/kong.yml" },
];

const cfg = (p) => JSON.stringify(p.config ?? null);

/**
 * Tira o prefixo do projeto quando ele está lá, para as chaves baterem dos dois
 * lados.
 *
 * 🐞 Não dá para tirar só do gerado: o gerador NÃO prefixa quem já começa com o
 * id do projeto, e `liveflow-sse` já se chamava assim na origem. Cortar de um
 * lado só fazia 14 rotas do live-flow parecerem "sumidas" — alarme falso que
 * esconde a divergência de verdade no meio do ruído.
 */
function semPrefixo(nome, id) {
  return id && nome.startsWith(id + "-") ? nome.slice(id.length + 1) : nome;
}

/**
 * Monta `rota → { nome do plugin → config }` já resolvido por precedência.
 *
 * `globais` é o que vale para o gateway inteiro naquele arquivo. No kong.yml de
 * um projeto isso quer dizer "todo o projeto"; no gerado, tem que ser vazio —
 * lá "global" quer dizer "todos os cinco projetos", que é outra coisa.
 *
 * `id` normaliza o nome (nos DOIS lados); `filtrar` seleciona só os services
 * daquele projeto (só faz sentido no gerado, que tem os cinco juntos).
 *
 * São coisas separadas de propósito: usar o mesmo parâmetro para as duas fazia
 * o lado original ficar sem normalização e 24 rotas virarem "sumiu".
 */
function efetivosPorRota(doc, { id, filtrar } = {}) {
  const globais = new Map();
  const porRotaRef = new Map();
  const porServicoRef = new Map();

  for (const p of doc.plugins ?? []) {
    if (p.route) {
      if (!porRotaRef.has(p.route)) porRotaRef.set(p.route, new Map());
      porRotaRef.get(p.route).set(p.name, cfg(p));
    } else if (p.service) {
      if (!porServicoRef.has(p.service)) porServicoRef.set(p.service, new Map());
      porServicoRef.get(p.service).set(p.name, cfg(p));
    } else if (p.consumer) {
      // fora do escopo desta conferência; nenhum projeto usa hoje
    } else {
      globais.set(p.name, cfg(p));
    }
  }

  const saida = new Map();

  for (const s of doc.services ?? []) {
    const nomeSvc = String(s.name ?? "");
    if (filtrar && !nomeSvc.startsWith(id + "-")) continue;
    const svcLimpo = semPrefixo(nomeSvc, id);

    const doServico = new Map(globais);
    for (const [n, c] of porServicoRef.get(nomeSvc) ?? []) doServico.set(n, c);
    for (const p of s.plugins ?? []) doServico.set(p.name, cfg(p));

    for (const r of s.routes ?? []) {
      const nomeRota = String(r.name ?? "");
      const rotaLimpa = semPrefixo(nomeRota, id);

      const daRota = new Map(doServico);
      for (const [n, c] of porRotaRef.get(nomeRota) ?? []) daRota.set(n, c);
      for (const p of r.plugins ?? []) daRota.set(p.name, cfg(p));

      saida.set(`${svcLimpo}/${rotaLimpa}`, daRota);
    }
  }
  return saida;
}

async function main() {
  const gerado = parse(await readFile(path.join("kong", "kong.yml"), "utf8"));

  // no gerado, NADA pode ser global: a config de `cors` difere entre os cinco,
  // e um `cors` global sem `origins` libera `*` para todo mundo
  const globaisIndevidos = (gerado.plugins ?? []).filter((p) => !p.route && !p.service);
  const problemas = globaisIndevidos.map(
    (p) => `plugin "${p.name}" ficou GLOBAL no gerado — vale para os cinco projetos de uma vez`
  );

  let rotasOk = 0;

  for (const proj of PROJETOS) {
    // 🐞 A base de comparação vem de `referencia/`, e NÃO dos repositórios
    // irmãos.
    //
    // Antes lia `../live-flow/deploy/kong/kong.yml` e companhia. Isso funciona
    // na estação, onde todos os repositórios são irmãos numa pasta só — e falha
    // no Jenkins, onde cada job tem espaço de trabalho próprio e não há irmão
    // nenhum. O build do gateway morria com
    // `ENOENT: /var/lib/jenkins/workspace/live-flow/deploy/kong/kong.yml`.
    //
    // Mas congelar não é só conveniência de CI: esta checagem prova que a
    // migração para o Kong único não PERDEU plugin em relação ao que existia
    // ANTES. Uma base que continua mudando permitiria enfraquecer os dois lados
    // juntos e a comparação seguir verde — que é precisamente o que ela deveria
    // impedir.
    //
    // ⚠️ Portanto `referencia/` é histórico. Só se mexe nele para corrigir uma
    // cópia errada, nunca para "atualizar".
    const congelado = path.join(RAIZ, "referencia", proj.id + ".yml");
    const original = parse(await readFile(congelado, "utf8"));
    const antes = efetivosPorRota(original, { id: proj.id, filtrar: false });
    const depois = efetivosPorRota(gerado, { id: proj.id, filtrar: true });

    for (const [rota, esperado] of antes) {
      const obtido = depois.get(rota);
      if (!obtido) {
        problemas.push(`${proj.id}: a rota "${rota}" sumiu do gerado`);
        continue;
      }
      for (const [nome, config] of esperado) {
        if (!obtido.has(nome)) {
          problemas.push(`${proj.id} ${rota}: perdeu o plugin "${nome}"`);
        } else if (obtido.get(nome) !== config) {
          problemas.push(`${proj.id} ${rota}: "${nome}" com config DIFERENTE`);
        }
      }
      for (const nome of obtido.keys()) {
        if (!esperado.has(nome)) {
          problemas.push(`${proj.id} ${rota}: ganhou "${nome}", que não existia`);
        }
      }
      rotasOk++;
    }
  }

  if (problemas.length) {
    console.error(`❌ ${problemas.length} divergência(s) de plugin:`);
    for (const p of problemas.slice(0, 40)) console.error("   • " + p);
    if (problemas.length > 40) console.error(`   … e mais ${problemas.length - 40}`);
    process.exit(1);
  }

  console.log(`✅ ${rotasOk} rotas conferidas — plugin efetivo idêntico ao Kong de origem`);
  console.log(`   nenhum plugin global (cada um preso ao projeto que o declarou)`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

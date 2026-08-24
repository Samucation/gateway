// Prova o caminho INTEIRO de envio de imagem, de dentro do Pod do urupix.
//
// ⚠️ Nao basta o `health` do sigma-midia responder 200: o envio tem tres
// passos, e cada um pode falhar por motivo proprio.
//
//   1. POST /api/v1/ativos            -> autoriza e devolve `urlParaEnviar`
//   2. PUT  na url assinada           -> manda os bytes para o MinIO
//   3. POST /api/v1/ativos/{id}/confirmar
//
// 🐞 O passo 2 e o que a virada tinha mais chance de quebrar: a url assinada
// aponta para o MinIO, e se ela vier com o endereco de FORA do cluster
// (`localhost:9100`), o Pod nao alcanca -- e o sintoma na tela e "arquivo
// invalido", exatamente o que o dono viu.
const base = process.env.MIDIA_BASE_URL;
const chave = process.env.MIDIA_API_KEY;

// Um PNG 1x1 de verdade, com assinatura valida: o servidor recusa o que nao
// for imagem, e um arquivo falso reprovaria por outro motivo.
const png = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
  'base64'
);

async function main() {
  console.log('base:', base ? 'ok' : 'VAZIA', '| chave:', chave ? 'ok' : 'VAZIA');

  const r1 = await fetch(base + '/api/v1/ativos', {
    method: 'POST',
    headers: { 'X-API-Key': chave, 'Content-Type': 'application/json' },
    // ⚠️ Os nomes dos campos vem do `src/lib/sigma-midia.ts`, e nao de
    // adivinhacao: `pasta`, `nomeOriginal`, `tipo`, `tamanho`. Errar o nome
    // devolve 400 com "informe o tipo" -- que parece campo ausente e e campo
    // com OUTRO nome.
    body: JSON.stringify({
      pasta: 'prova',
      nomeOriginal: 'prova-virada.png',
      tipo: 'image/png',
      tamanho: png.length,
    }),
  });
  const t1 = await r1.text();
  console.log('1) autorizar:', r1.status, t1.slice(0, 200));
  if (!r1.ok) return;

  const { ativoId, urlParaEnviar } = JSON.parse(t1);

  // ⚠️ Imprime o HOST da url assinada. Se aparecer `localhost`, o Pod nao vai
  // alcancar -- e e esse detalhe que a virada quebra sem avisar.
  console.log('   host do envio:', new URL(urlParaEnviar).host);

  const r2 = await fetch(urlParaEnviar, {
    method: 'PUT',
    headers: { 'Content-Type': 'image/png' },
    body: png,
  });
  console.log('2) enviar bytes:', r2.status);
  if (!r2.ok) return;

  const r3 = await fetch(base + '/api/v1/ativos/' + ativoId + '/confirmar', {
    method: 'POST',
    headers: { 'X-API-Key': chave, 'Content-Type': 'application/json' },
    body: JSON.stringify({}),
  });
  const t3 = await r3.text();
  console.log('3) confirmar:', r3.status, t3.slice(0, 160));

  if (r3.ok) console.log('RESULTADO: envio de imagem FUNCIONA de ponta a ponta');
}

main().catch((e) => console.log('ERRO:', e.message));

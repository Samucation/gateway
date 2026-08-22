/* ===========================================================================
   PAINEL DAS ESTEIRAS

   Servido pelo próprio Jenkins, em /userContent/painel/painel.html

   ---------------------------------------------------------------------------
   🐞 POR QUE O SCRIPT ESTÁ NUM ARQUIVO SEPARADO
   ---------------------------------------------------------------------------
   A primeira versão tinha o JavaScript embutido no HTML — e a página abria em
   branco, sem um dado sequer. O Jenkins serve `/userContent` com

       Content-Security-Policy: default-src 'none'; img-src 'self'; style-src 'self';

   `default-src 'none'` bloqueia TODO script. A página carregava, o navegador
   descartava o código em silêncio, e nada aparecia.

   ⚠️ A saída fácil seria liberar `unsafe-inline`, mas isso permitiria script
   embutido em QUALQUER arquivo servido por `/userContent` — inclusive um que
   alguém deixe lá sem pensar. Com o código num arquivo, a política pode ser
   `script-src 'self'`, que libera exatamente isto e mais nada.

   ---------------------------------------------------------------------------
   ⚠️ NÃO GUARDA CREDENCIAL
   ---------------------------------------------------------------------------
   Tudo usa a sessão do navegador que já está aberta. Um token aqui seria mais
   um segredo para vazar, e ficaria velho na primeira rotação.
   =========================================================================== */
'use strict';

// Caminho RELATIVO: a página é servida pelo próprio Jenkins, então isto vale
// pelo túnel, por IP ou por localhost — e nunca aponta para o Jenkins errado.
const RAIZ = new URL('../../', location.href).pathname;
const QUANTAS = 20;
const INTERVALO = 10000;

// O que cada esteira era na leitura anterior. É a comparação disto com a
// leitura nova que dispara o aviso de "terminou".
const anterior = new Map();
let primeiraLeitura = true;

async function pegar(caminho) {
  const r = await fetch(RAIZ + caminho, { credentials: 'same-origin' });
  if (!r.ok) throw new Error(caminho + ' devolveu ' + r.status);
  return r.json();
}

// ⚠️ O Jenkins recusa POST sem o "crumb" (proteção contra CSRF), e a recusa vem
// como 403 com uma página HTML — que num script parece "sem permissão", quando
// na verdade é só um cabeçalho faltando.
async function crumb() {
  const c = await pegar('crumbIssuer/api/json');
  return { [c.crumbRequestField]: c.crumb };
}

async function postar(caminho) {
  const cabecalhos = await crumb();
  const r = await fetch(RAIZ + caminho, {
    method: 'POST', credentials: 'same-origin', headers: cabecalhos,
  });
  // 201 e 302 são respostas normais do Jenkins para disparo e parada.
  if (!r.ok && r.status !== 302) throw new Error('devolveu ' + r.status);
}

function classeDe(resultado, rodando) {
  if (rodando) return 'rodando';
  if (resultado === 'SUCCESS') return 'ok';
  if (resultado === 'FAILURE') return 'erro';
  if (resultado === 'UNSTABLE') return 'instavel';
  return 'abortado';
}

function textoDe(resultado, rodando) {
  if (rodando) return 'rodando agora';
  if (resultado === 'SUCCESS') return 'passou';
  if (resultado === 'FAILURE') return 'quebrou';
  if (resultado === 'UNSTABLE') return 'passou com ressalva';
  if (resultado === 'ABORTED') return 'interrompida';
  return resultado || 'sem execução';
}

function quando(ms) {
  if (!ms) return '';
  const s = Math.floor((Date.now() - ms) / 1000);
  if (s < 60) return 'agora há pouco';
  const m = Math.floor(s / 60);
  if (m < 60) return m + ' min';
  const h = Math.floor(m / 60);
  if (h < 48) return h + ' h';
  return Math.floor(h / 24) + ' d';
}

// Duracao em texto curto: 45s, 3m12s, 1h04m.
function duracao(ms) {
  if (!ms || ms < 0) return '—';
  const s = Math.round(ms / 1000);
  if (s < 60) return s + 's';
  const m = Math.floor(s / 60);
  if (m < 60) return m + 'm' + String(s % 60).padStart(2, '0') + 's';
  return Math.floor(m / 60) + 'h' + String(m % 60).padStart(2, '0') + 'm';
}

function caixa(n, rotulo, cor) {
  return '<div class="caixa"><div class="n" style="color:' + cor + '">' + n +
         '</div><div class="r">' + rotulo + '</div></div>';
}

// ---------------------------------------------------------------------------
// AVISO NA TELA quando uma esteira termina
//
// ⚠️ A permissão tem que ser pedida por um CLIQUE. O navegador ignora — e em
// alguns casos passa a NEGAR para sempre — pedidos disparados sozinhos ao
// carregar a página. Por isso existe o botão.
// ---------------------------------------------------------------------------
function avisar(projeto, resultado) {
  if (!('Notification' in window) || Notification.permission !== 'granted') return;
  const passou = resultado === 'SUCCESS';
  new Notification(
    (passou ? '✅ ' : '❌ ') + projeto,
    {
      body: passou ? 'A esteira terminou com sucesso.'
                   : 'A esteira terminou com ' + textoDe(resultado, false) + '.',
      // A etiqueta evita empilhar dez avisos do mesmo projeto: o novo
      // SUBSTITUI o anterior.
      tag: 'esteira-' + projeto,
    },
  );
}

async function botaoDeAviso() {
  const b = document.getElementById('permitir');
  if (!('Notification' in window)) { b.textContent = 'sem suporte a aviso'; b.disabled = true; return; }
  if (Notification.permission === 'granted') { b.textContent = '🔔 avisos ligados'; b.disabled = true; return; }
  if (Notification.permission === 'denied') { b.textContent = '🔕 avisos bloqueados no navegador'; b.disabled = true; return; }
  b.onclick = async () => {
    const p = await Notification.requestPermission();
    b.textContent = p === 'granted' ? '🔔 avisos ligados' : '🔕 avisos bloqueados no navegador';
    b.disabled = true;
  };
}

// ---------------------------------------------------------------------------
// A confirmação antes de PARAR
//
// ⚠️ Parar é destrutivo e o botão fica ao lado do de reenviar. Sem a pergunta,
// um clique errado joga fora uma construção de vários minutos — e, pior, pode
// interromper um deploy no meio.
// ---------------------------------------------------------------------------
function confirmar(titulo, texto) {
  return new Promise((resolve) => {
    const veu = document.getElementById('veu');
    document.getElementById('dlg-titulo').textContent = titulo;
    document.getElementById('dlg-texto').textContent = texto;
    veu.hidden = false;

    const fecha = (r) => {
      veu.hidden = true;
      document.getElementById('dlg-sim').onclick = null;
      document.getElementById('dlg-nao').onclick = null;
      resolve(r);
    };
    document.getElementById('dlg-sim').onclick = () => fecha(true);
    document.getElementById('dlg-nao').onclick = () => fecha(false);
  });
}

async function carregar() {
  const sub = document.getElementById('sub');
  let jobs;
  try {
    const v = await pegar('view/Painel/api/json?tree=jobs[name,url,fullName]');
    jobs = v.jobs || [];
  } catch (e) {
    sub.innerHTML = '<span class="erro-carga">não consegui falar com o Jenkins: ' + e.message + '</span>';
    return;
  }

  const grade = document.getElementById('grade');
  const barras = document.getElementById('barras');
  const novaGrade = document.createDocumentFragment();
  const novasBarras = document.createDocumentFragment();

  let nOk = 0, nErro = 0, nRodando = 0, nOutro = 0;

  // Em paralelo: dez projetos em série levariam dez idas ao servidor.
  const dados = await Promise.all(jobs.map(async (j) => {
    const base = new URL(j.url).pathname.slice(1);
    const fora = { job: j, base, ultima: null, etapas: [], historico: [], totalEsperado: 0 };
    try {
      // `estimatedDuration` e o que o Jenkins calcula a partir das execucoes
      // anteriores. E dele que sai a porcentagem enquanto a esteira roda.
      fora.ultima = await pegar(base + 'lastBuild/api/json?tree=number,building,result,timestamp,estimatedDuration');
    } catch (e) { /* sem execução ainda */ }
    try {
      const d = await pegar(base + 'lastBuild/wfapi/describe');
      fora.etapas = d.stages || [];
    } catch (e) { /* sem etapas registradas */ }
    try {
      // ⚠️ Quantas etapas a esteira TEM, e nao quantas ja apareceram.
      //
      // 🐞 Uma execucao em andamento so registra as etapas que ja alcancou --
      // foi isso que fez a esteira "parecer menor". Para dizer "fase 5 de 14" e
      // preciso perguntar a ULTIMA EXECUCAO COMPLETA quantas existem.
      const c = await pegar(base + 'lastCompletedBuild/wfapi/describe');
      fora.totalEsperado = (c.stages || []).length;
    } catch (e) { /* sem execução completa ainda */ }
    try {
      const h = await pegar(base + 'api/json?tree=builds[result,building]{0,' + QUANTAS + '}');
      fora.historico = h.builds || [];
    } catch (e) { /* sem histórico */ }
    return fora;
  }));

  for (const d of dados) {
    const nome = d.job.fullName.replace('/main', '');
    const rodando = !!(d.ultima && d.ultima.building);
    const resultado = d.ultima ? d.ultima.result : null;
    const cls = classeDe(resultado, rodando);

    if (rodando) nRodando++;
    else if (cls === 'ok') nOk++;
    else if (cls === 'erro') nErro++;
    else nOutro++;

    // ⚠️ Avisa só na TRANSIÇÃO de rodando para parado. Sem isto, a página
    // gritaria a cada 10 segundos para toda esteira já terminada.
    const antes = anterior.get(nome);
    if (!primeiraLeitura && antes && antes.rodando && !rodando) {
      avisar(nome, resultado);
    }
    anterior.set(nome, { rodando, resultado });

    const agora = d.etapas.find((s) => s.status === 'IN_PROGRESS');

    // ---- o passo a passo, para nao ficar as cegas -------------------------
    let progresso = '';
    if (rodando && d.etapas.length === 0) {
      // ⚠️ ZERO etapas com a execucao "rodando" quase sempre significa FILA.
      //
      // 🐞 Sem este caso, a conta por tempo tomava conta: uma espera de 12
      // minutos com nada acontecendo aparecia como "99%", porque o decorrido ja
      // passara do previsto. A barra dizia "quase la" enquanto a esteira nem
      // tinha comecado -- a mentira mais irritante que um painel pode contar.
      //
      // Com UM executor, esperar e o normal, nao a excecao.
      const espera = d.ultima.timestamp ? Date.now() - d.ultima.timestamp : 0;
      progresso =
        '<div class="progresso aguardando"><i style="width:100%"></i></div>' +
        '<div class="passo"><span>na fila, esperando executor</span>' +
        '<span class="pct">há ' + duracao(espera) + '</span></div>';
    } else if (rodando) {
      const total = Math.max(d.totalEsperado, d.etapas.length);
      const indice = d.etapas.length;
      const decorrido = d.ultima.timestamp ? Date.now() - d.ultima.timestamp : 0;
      const previsto = d.ultima.estimatedDuration || 0;

      // ⚠️ DUAS medidas de progresso, e a maior manda.
      //
      // Por ETAPA e honesta mas grosseira: pula de 7% em 7% e fica parada
      // minutos numa etapa longa, dando impressao de travamento.
      //
      // Por TEMPO e suave, mas mente quando a execucao passa do previsto --
      // e ai encosta em 99% e fica la.
      //
      // Juntas: a barra anda sempre, e nunca finge que terminou.
      const porEtapa = total ? (indice / total) * 100 : 0;
      const porTempo = previsto ? Math.min((decorrido / previsto) * 100, 99) : 0;
      const pct = Math.min(Math.max(porEtapa, porTempo), 99);

      const passo = total ? 'fase ' + indice + ' de ' + total : 'fase ' + indice;
      const tempo = duracao(decorrido) + (previsto ? ' de ~' + duracao(previsto) : '');

      progresso =
        '<div class="progresso"><i style="width:' + pct.toFixed(0) + '%"></i></div>' +
        '<div class="passo">' +
          '<span>' + passo + ' · <b>' + (agora ? agora.name : '…') + '</b></span>' +
          '<span class="pct">' + pct.toFixed(0) + '% · ' + tempo + '</span>' +
        '</div>';
    } else if (d.etapas.length) {
      // Parada: mostra ONDE parou. Numa que quebrou, e a primeira coisa que se
      // quer saber -- e evita abrir o log so para descobrir a etapa.
      const falhou = d.etapas.find((s) => s.status === 'FAILED');
      const total = Math.max(d.totalEsperado, d.etapas.length);
      const dur = d.etapas.reduce((a, s) => a + (s.durationMillis || 0), 0);
      progresso =
        '<div class="passo"><span>' +
        (falhou ? 'parou em <b>' + falhou.name + '</b>'
                : d.etapas.length + ' de ' + total + ' fases') +
        '</span><span class="pct">' + duracao(dur) + '</span></div>';
    }

    const bolinhas = d.etapas.map((s) => {
      let c = '';
      if (s.status === 'SUCCESS') c = 'ok';
      else if (s.status === 'FAILED') c = 'erro';
      else if (s.status === 'IN_PROGRESS') c = 'agora';
      else if (s.status === 'SKIPPED' || s.status === 'NOT_EXECUTED') c = 'pulada';
      return '<span class="fase ' + c + '" title="' + s.name + ': ' + s.status + '"></span>';
    }).join('');

    const el = document.createElement('div');
    el.className = 'esteira ' + cls;
    el.innerHTML =
      '<div class="topo">' +
        '<span class="nome"><a href="' + RAIZ + d.base + '">' + nome + '</a></span>' +
        '<span class="quando">' + (d.ultima ? '#' + d.ultima.number + ' · ' + quando(d.ultima.timestamp) : '') + '</span>' +
      '</div>' +
      '<div class="estado ' + cls + '">' + textoDe(resultado, rodando) + '</div>' +
      (bolinhas ? '<div class="fases">' + bolinhas + '</div>' : '') +
      progresso;

    const acoes = document.createElement('div');
    acoes.className = 'acoes';

    const bReenviar = document.createElement('button');
    bReenviar.textContent = '▶ reenviar';
    bReenviar.disabled = rodando;
    bReenviar.onclick = async () => {
      bReenviar.disabled = true;
      try {
        // Job com parâmetro exige `/buildWithParameters`; sem parâmetro,
        // `/build`. Trocar os dois devolve 400 sem dizer o que faltou.
        try { await postar(d.base + 'buildWithParameters'); }
        catch (e) { await postar(d.base + 'build'); }
        sub.textContent = nome + ': disparada';
      } catch (e) {
        sub.innerHTML = '<span class="erro-carga">não consegui disparar ' + nome + ': ' + e.message + '</span>';
        bReenviar.disabled = false;
      }
    };

    const bParar = document.createElement('button');
    bParar.textContent = '■ parar';
    bParar.className = 'perigo';
    bParar.disabled = !rodando;
    bParar.onclick = async () => {
      const ok = await confirmar(
        'Parar ' + nome + '?',
        'A execução #' + (d.ultima ? d.ultima.number : '?') +
        ' está na fase "' + (agora ? agora.name : '—') +
        '". Parar agora joga fora o que já foi feito, e se ela estiver no meio de ' +
        'uma implantação o ambiente pode ficar pela metade.',
      );
      if (!ok) return;
      bParar.disabled = true;
      try {
        await postar(d.base + 'lastBuild/stop');
        sub.textContent = nome + ': parada solicitada';
      } catch (e) {
        sub.innerHTML = '<span class="erro-carga">não consegui parar ' + nome + ': ' + e.message + '</span>';
      }
    };

    acoes.appendChild(bReenviar);
    acoes.appendChild(bParar);
    el.appendChild(acoes);
    novaGrade.appendChild(el);

    // ---- a barra do gráfico ------------------------------------------------
    const h = d.historico.filter((b) => !b.building);
    const v = h.filter((b) => b.result === 'SUCCESS').length;
    const x = h.filter((b) => b.result === 'FAILURE' || b.result === 'UNSTABLE').length;
    const a = h.length - v - x;
    const t = h.length || 1;

    const linha = document.createElement('div');
    linha.className = 'barra-linha';
    linha.innerHTML =
      '<div class="barra-nome">' + nome + '</div>' +
      '<div class="barra">' +
        '<i class="v" style="width:' + (v / t * 100) + '%"></i>' +
        '<i class="x" style="width:' + (x / t * 100) + '%"></i>' +
        '<i class="a" style="width:' + (a / t * 100) + '%"></i>' +
      '</div>' +
      '<div class="barra-num">' + v + ' ok · ' + x + ' erro' + (a ? ' · ' + a + ' int.' : '') + '</div>';
    novasBarras.appendChild(linha);
  }

  grade.replaceChildren(novaGrade);
  barras.replaceChildren(novasBarras);

  document.getElementById('resumo').innerHTML =
    caixa(nRodando, 'rodando', 'var(--rodando)') +
    caixa(nOk, 'passou', 'var(--ok)') +
    caixa(nErro, 'quebrou', 'var(--erro)') +
    caixa(nOutro, 'outros', 'var(--abortado)');

  sub.textContent = jobs.length + ' esteiras · atualiza sozinho a cada 10 s · ' +
                    new Date().toLocaleTimeString('pt-BR');
  primeiraLeitura = false;
}

botaoDeAviso();
carregar();
setInterval(carregar, INTERVALO);

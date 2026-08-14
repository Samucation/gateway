import { Component, inject, signal, computed, OnDestroy } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { ActivatedRoute } from '@angular/router';

interface PontoDaSerie { minuto: string; total: number; bloqueadas: number; }
interface IpVisto {
  ip: string; total: number; bloqueadas: number;
  semAutorizacao: number; naoEncontradas: number; caminhos: string[];
}
interface Alerta { nivel: 'alto' | 'medio'; ip: string; texto: string; }
interface Trafego {
  minutos: number; total: number; bloqueadas: number;
  serie: PontoDaSerie[]; ips: IpVisto[];
  porStatus: Record<string, number>; porRota: Record<string, number>;
  alertas: Alerta[]; sinais: Record<string, number>;
}

/**
 * Tráfego e abuso, do jeito que dá para agir.
 *
 * O gráfico vem do log de acesso do Kong — a única fonte que tem o IP de quem
 * pediu. As métricas do Prometheus agregam por rota e status, e por isso não
 * respondem a pergunta que interessa num ataque: QUEM.
 */
@Component({
  selector: 'gw-trafego',
  standalone: true,
  imports: [CommonModule],
  template: `
    <h1 class="page-title">Tráfego e ataques</h1>
    <p class="page-sub">
      Lido do log de acesso do gateway. Atualiza sozinho a cada 15 s.
    </p>

    <div class="toolbar">
      @for (m of [15, 30, 60, 180]; track m) {
        <button [class.ativo]="minutos() === m" (click)="trocarJanela(m)">{{ m }} min</button>
      }
      <span class="grow"></span>
      @if (carregando()) { <span class="spinner"></span> }
    </div>

    <div class="toolbar">
      <select [value]="app()" (change)="mudar('app', $any($event.target).value)">
        <option value="">todas as aplicacoes</option>
        @for (a of APPS; track a.id) { <option [value]="a.id">{{ a.nome }}</option> }
      </select>
      <select [value]="status()" (change)="mudar('status', $any($event.target).value)">
        <option value="">todas as respostas</option>
        @for (c of CODIGOS; track c) { <option [value]="c">{{ c }}</option> }
      </select>
      <input type="text" placeholder="filtrar por caminho..." [value]="filtroCaminho()"
             (change)="mudar('caminho', $any($event.target).value)" />
      <input type="text" placeholder="filtrar por endereco IP..." [value]="ip()"
             (change)="mudar('ip', $any($event.target).value)" />
      @if (temFiltro()) { <button (click)="limpar()">limpar filtros</button> }
    </div>

    @if (dados(); as d) {
      <!-- alertas primeiro: é o que exige ação -->
      @if (d.alertas.length) {
        <div class="alertas">
          @for (a of d.alertas; track a.ip + a.texto) {
            <div class="alerta" [class.alto]="a.nivel === 'alto'">
              <strong>{{ a.ip }}</strong> — {{ a.texto }}
            </div>
          }
        </div>
      } @else {
        <div class="tranquilo">Nenhum sinal de abuso nos últimos {{ d.minutos }} minutos.</div>
      }

      <div class="cartoes">
        <div class="cartao">
          <div class="numero">{{ d.total }}</div>
          <div class="rotulo">requisições</div>
        </div>
        <div class="cartao" [class.destaque]="d.bloqueadas > 0">
          <div class="numero">{{ d.bloqueadas }}</div>
          <div class="rotulo">bloqueadas (429)</div>
        </div>
        <div class="cartao">
          <div class="numero">{{ d.ips.length }}</div>
          <div class="rotulo">endereços distintos</div>
        </div>
        <div class="cartao">
          <div class="numero">{{ porMinuto() }}</div>
          <div class="rotulo">req/min (média)</div>
        </div>
      </div>

      <h2 class="secao">Requisições por minuto</h2>
      <svg class="grafico" [attr.viewBox]="'0 0 ' + LARGURA + ' ' + ALTURA" preserveAspectRatio="none">
        <defs>
          <linearGradient id="preenche" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="#4f8cff" stop-opacity="0.45" />
            <stop offset="100%" stop-color="#4f8cff" stop-opacity="0.02" />
          </linearGradient>
        </defs>
        <path class="area" [attr.d]="area()" fill="url(#preenche)" />
        <path class="linha" [attr.d]="linha()" fill="none" stroke="#4f8cff" stroke-width="2" />
        @if (temBloqueio()) {
          <path class="linha bloq" [attr.d]="linhaBloqueadas()" fill="none" stroke="#ff6b6b" stroke-width="2" />
        }
      </svg>
      <p class="page-sub legenda">
        <span class="chave azul"></span> total
        @if (temBloqueio()) { <span class="chave vermelha"></span> bloqueadas }
        <span class="grow"></span> pico: {{ pico() }} req/min
      </p>

      <h2 class="secao">Respostas</h2>
      <div class="barras">
        @for (s of statusOrdenado(); track s.codigo) {
          <div class="barra-linha">
            <span class="codigo" [class.erro]="s.codigo >= '400'">{{ s.codigo }}</span>
            <div class="trilho">
              <div class="preenchimento" [class.erro]="s.codigo >= '400'"
                   [style.width.%]="s.pct"></div>
            </div>
            <span class="valor">{{ s.n }}</span>
          </div>
        }
      </div>

      <h2 class="secao">Quem mais pediu</h2>
      <table>
        <thead>
          <tr><th>Endereço</th><th>Total</th><th>Bloqueadas</th><th>401/403</th><th>404</th><th>Caminhos</th></tr>
        </thead>
        <tbody>
          @for (x of d.ips; track x.ip) {
            <tr [class.suspeito]="suspeito(x)">
              <td><code>{{ x.ip }}</code></td>
              <td><strong>{{ x.total }}</strong></td>
              <td [class.erro]="x.bloqueadas > 0">{{ x.bloqueadas }}</td>
              <td [class.erro]="x.semAutorizacao > 0">{{ x.semAutorizacao }}</td>
              <td>{{ x.naoEncontradas }}</td>
              <td class="caminhos">@for (c of x.caminhos.slice(0, 4); track c) { <span class="badge muted">{{ c }}</span> }</td>
            </tr>
          }
        </tbody>
      </table>

      <h2 class="secao">Caminhos mais pedidos</h2>
      <table>
        <tbody>
          @for (r of rotasOrdenadas(); track r.caminho) {
            <tr><td><code>{{ r.caminho }}</code></td><td style="width:6rem">{{ r.n }}</td></tr>
          }
        </tbody>
      </table>
    } @else if (erro()) {
      <div class="error-box">{{ erro() }}</div>
    }
  `,
  styles: [`
    .cartoes { display: grid; grid-template-columns: repeat(4, 1fr); gap: .75rem; margin: 1rem 0; }
    .cartao { background: #161b22; border: 1px solid #262d36; border-radius: 10px; padding: .9rem 1rem; }
    .cartao.destaque { border-color: #ff6b6b55; }
    .numero { font-size: 1.7rem; font-weight: 700; transition: color .3s ease; }
    .rotulo { font-size: .75rem; opacity: .6; margin-top: .15rem; }
    .secao { font-size: 1rem; margin: 1.4rem 0 .5rem; opacity: .85; }

    .grafico { width: 100%; height: 180px; background: #0f1319; border: 1px solid #262d36; border-radius: 10px; }
    /* a linha se DESENHA quando os dados chegam; sem isso a troca de janela
       parece um salto e não dá para ver o que mudou */
    .linha { stroke-linejoin: round; stroke-linecap: round;
             stroke-dasharray: 2000; stroke-dashoffset: 0; animation: desenhar .9s ease-out; }
    .area { animation: aparecer .9s ease-out; }
    @keyframes desenhar { from { stroke-dashoffset: 2000; } to { stroke-dashoffset: 0; } }
    @keyframes aparecer { from { opacity: 0; } to { opacity: 1; } }
    .legenda { display: flex; align-items: center; gap: .4rem; }
    .chave { width: 12px; height: 3px; border-radius: 2px; display: inline-block; }
    .chave.azul { background: #4f8cff; } .chave.vermelha { background: #ff6b6b; }

    .barras { display: flex; flex-direction: column; gap: .3rem; }
    .barra-linha { display: grid; grid-template-columns: 3rem 1fr 4rem; align-items: center; gap: .6rem; }
    .trilho { background: #161b22; border-radius: 4px; height: 14px; overflow: hidden; }
    .preenchimento { background: #4f8cff; height: 100%; border-radius: 4px;
                     transition: width .6s cubic-bezier(.2,.8,.2,1); }
    .preenchimento.erro { background: #ff6b6b; }
    .codigo.erro, td.erro { color: #ff8f8f; }
    .valor { text-align: right; font-variant-numeric: tabular-nums; }

    .alertas { display: flex; flex-direction: column; gap: .4rem; margin: .8rem 0; }
    .alerta { border-left: 3px solid #ffa94d; background: #1d1a12; padding: .6rem .8rem; border-radius: 6px; }
    .alerta.alto { border-left-color: #ff6b6b; background: #1f1414; animation: pulsar 1.6s ease-in-out infinite; }
    @keyframes pulsar { 0%,100% { box-shadow: 0 0 0 0 #ff6b6b00; } 50% { box-shadow: 0 0 0 3px #ff6b6b22; } }
    .tranquilo { background: #121a14; border-left: 3px solid #4caf7d; padding: .6rem .8rem; border-radius: 6px; margin: .8rem 0; }
    tr.suspeito { background: #1f141433; }
    .caminhos { max-width: 28rem; }
  `],
})
export class TrafegoComponent implements OnDestroy {
  private http = inject(HttpClient);
  readonly LARGURA = 600;
  readonly ALTURA = 180;

  readonly APPS = [
    { id: 'liveflow', nome: 'Urupix / live-flow' },
    { id: 'sigmafin', nome: 'Sigma Financeiro' },
    { id: 'plataforma', nome: 'Plataforma de Atendimento' },
    { id: 'central', nome: 'Central de IA' },
    { id: 'sigmapay', nome: 'Sigma Payments' },
  ];
  readonly CODIGOS = ['200', '301', '304', '400', '401', '403', '404', '429', '500', '502'];

  dados = signal<Trafego | null>(null);
  minutos = signal(15);
  app = signal('');
  status = signal('');
  filtroCaminho = signal('');
  ip = signal('');
  carregando = signal(false);
  erro = signal<string | null>(null);
  private timer: ReturnType<typeof setInterval>;

  constructor() {
    // a tela de Aplicacoes manda para ca com ?app=..., entao o filtro precisa
    // nascer da URL; sem isso o link "ver acessos" abriria a visao geral e
    // pareceria que o clique nao fez nada
    const q = inject(ActivatedRoute).snapshot.queryParamMap;
    if (q.get('app')) this.app.set(q.get('app')!);
    this.buscar();
    this.timer = setInterval(() => this.buscar(), 15000);
  }

  mudar(campo: 'app' | 'status' | 'caminho' | 'ip', valor: string) {
    ({ app: this.app, status: this.status, caminho: this.filtroCaminho, ip: this.ip })[campo].set(valor.trim());
    this.buscar();
  }
  limpar() {
    this.app.set(''); this.status.set(''); this.filtroCaminho.set(''); this.ip.set('');
    this.buscar();
  }
  temFiltro() { return !!(this.app() || this.status() || this.filtroCaminho() || this.ip()); }
  ngOnDestroy() { clearInterval(this.timer); }

  trocarJanela(m: number) { this.minutos.set(m); this.buscar(); }

  buscar() {
    this.carregando.set(true);
    const q = new URLSearchParams({ minutos: String(this.minutos()) });
    if (this.app()) q.set('app', this.app());
    if (this.status()) q.set('status', this.status());
    if (this.filtroCaminho()) q.set('caminho', this.filtroCaminho());
    if (this.ip()) q.set('ip', this.ip());
    this.http.get<Trafego>(`/api/trafego?${q}`).subscribe({
      next: (d) => { this.dados.set(d); this.carregando.set(false); },
      error: (e) => { this.erro.set(String(e.message ?? e)); this.carregando.set(false); },
    });
  }

  private serie = computed(() => this.dados()?.serie ?? []);
  pico = computed(() => Math.max(0, ...this.serie().map((p) => p.total)));
  temBloqueio = computed(() => this.serie().some((p) => p.bloqueadas > 0));
  porMinuto = computed(() => {
    const d = this.dados();
    return d && d.minutos ? Math.round(d.total / d.minutos) : 0;
  });

  /** Escala sempre pelo PICO, nunca por um teto fixo: com teto o gráfico fica
   *  rente ao chão em dia calmo e some justo quando o movimento cresce. */
  private caminho(pegar: (p: PontoDaSerie) => number, fechar: boolean): string {
    const pts = this.serie();
    if (pts.length < 2) return '';
    const max = Math.max(1, this.pico());
    const passo = this.LARGURA / (pts.length - 1);
    const y = (v: number) => this.ALTURA - (v / max) * (this.ALTURA - 12) - 6;
    const d = pts.map((p, i) => `${i ? 'L' : 'M'}${(i * passo).toFixed(1)},${y(pegar(p)).toFixed(1)}`).join(' ');
    return fechar ? `${d} L${this.LARGURA},${this.ALTURA} L0,${this.ALTURA} Z` : d;
  }
  linha = computed(() => this.caminho((p) => p.total, false));
  area = computed(() => this.caminho((p) => p.total, true));
  linhaBloqueadas = computed(() => this.caminho((p) => p.bloqueadas, false));

  statusOrdenado = computed(() => {
    const d = this.dados();
    if (!d) return [];
    const total = Math.max(1, d.total);
    return Object.entries(d.porStatus).map(([codigo, n]) => ({ codigo, n, pct: (n / total) * 100 }));
  });

  rotasOrdenadas = computed(() =>
    Object.entries(this.dados()?.porRota ?? {}).map(([caminho, n]) => ({ caminho, n }))
  );

  suspeito(x: IpVisto): boolean {
    const s = this.dados()?.sinais ?? {};
    return (
      x.total >= (s['requisicoesPorIp'] ?? Infinity) ||
      x.bloqueadas >= (s['bloqueiosPorIp'] ?? Infinity) ||
      x.semAutorizacao >= (s['errosDeAutenticacao'] ?? Infinity) ||
      x.naoEncontradas >= (s['naoEncontradosPorIp'] ?? Infinity)
    );
  }
}

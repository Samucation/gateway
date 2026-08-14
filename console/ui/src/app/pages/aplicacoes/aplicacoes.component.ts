import { Component, inject, signal, computed, OnDestroy } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { RouterLink } from '@angular/router';

interface AppTrafego {
  app: string; nome: string; total: number; bloqueadas: number;
  erros: number; bytes: number; mediaMs: number;
}
interface Trafego { minutos: number; total: number; bloqueadas: number; apps: AppTrafego[]; alertas: unknown[]; }
interface Amostra { quando: string; apps: { app: string; total: number; bloqueadas: number }[]; }
interface Projeto { id: string; nome: string; existe: boolean; services?: { rotas: unknown[] }[]; }
interface Estado { noAr: boolean; estado: string; saude: string; reinicios: string; conexoes: Record<string, number> | null; }

/**
 * As cinco aplicações, lado a lado.
 *
 * Só existe porque o log passou a registrar o host: antes disso um `GET /` não
 * dizia se era o Urupix, o Sigma ou o cafe — os cinco compartilham os mesmos
 * caminhos, e por isso a unificação exige `hosts:` em toda rota.
 */
@Component({
  selector: 'gw-aplicacoes',
  standalone: true,
  imports: [CommonModule, RouterLink],
  template: `
    <h1 class="page-title">Aplicações</h1>
    <p class="page-sub">Movimento das últimas {{ minutos() }} min, por aplicação. Atualiza a cada 15 s.</p>

    <div class="toolbar">
      @for (m of [15, 60, 180]; track m) {
        <button [class.ativo]="minutos() === m" (click)="trocar(m)">{{ m }} min</button>
      }
      <span class="grow"></span>
      @if (estado(); as e) {
        <span class="badge" [class.ok]="e.noAr">gateway {{ e.noAr ? 'no ar' : 'FORA' }}</span>
        <span class="badge muted">{{ e.saude }}</span>
        @if (e.conexoes) { <span class="badge muted">{{ e.conexoes['connections_active'] }} conexões</span> }
      }
    </div>

    <div class="grade">
      @for (a of cartoes(); track a.app) {
        <div class="app" [class.quieta]="a.total === 0" [class.alerta]="a.bloqueadas > 0 || a.erros > 0">
          <div class="topo">
            <strong>{{ a.nome }}</strong>
            <span class="badge muted">{{ a.rotas }} rotas</span>
          </div>

          <div class="numeros">
            <div><span class="n">{{ a.total }}</span><span class="l">requisições</span></div>
            <div><span class="n" [class.ruim]="a.bloqueadas > 0">{{ a.bloqueadas }}</span><span class="l">bloqueadas</span></div>
            <div><span class="n" [class.ruim]="a.erros > 0">{{ a.erros }}</span><span class="l">erros 5xx</span></div>
            <div><span class="n" [class.lento]="a.mediaMs > 1000">{{ a.mediaMs }}<small>ms</small></span><span class="l">média</span></div>
          </div>

          <!-- histórico curto: cada barra é uma amostra de 5 min gravada em disco,
               então continua existindo depois que o log do docker rodou -->
          <svg class="mini" viewBox="0 0 120 28" preserveAspectRatio="none">
            @for (b of a.barras; track $index) {
              <rect class="b" [attr.x]="$index * 4" [attr.y]="28 - b.h" width="3" [attr.height]="b.h"
                    [class.bloq]="b.bloq" />
            }
          </svg>

          <a routerLink="/trafego" [queryParams]="{ app: a.app }" class="link-mini">ver acessos →</a>
        </div>
      }
    </div>

    @if (semDados()) {
      <div class="tranquilo">
        Nenhuma requisição na janela. As aplicações podem estar simplesmente paradas —
        isto mostra movimento, não disponibilidade.
      </div>
    }
  `,
  styles: [`
    .grade { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: .8rem; margin-top: 1rem; }
    .app { background: #161b22; border: 1px solid #262d36; border-radius: 10px; padding: .9rem 1rem;
           transition: border-color .3s ease, transform .2s ease; }
    .app:hover { transform: translateY(-2px); }
    .app.quieta { opacity: .55; }
    .app.alerta { border-color: #ff6b6b55; }
    .topo { display: flex; justify-content: space-between; align-items: center; gap: .5rem; margin-bottom: .7rem; }
    .numeros { display: grid; grid-template-columns: repeat(4, 1fr); gap: .4rem; }
    .numeros > div { display: flex; flex-direction: column; }
    .n { font-size: 1.25rem; font-weight: 700; font-variant-numeric: tabular-nums; transition: color .3s ease; }
    .n small { font-size: .65rem; opacity: .6; margin-left: 1px; }
    .n.ruim { color: #ff8f8f; }
    .n.lento { color: #ffc078; }
    .l { font-size: .65rem; opacity: .55; }
    .mini { width: 100%; height: 28px; margin: .7rem 0 .3rem; }
    .mini .b { fill: #4f8cff; opacity: .75; transition: height .5s cubic-bezier(.2,.8,.2,1); }
    .mini .b.bloq { fill: #ff6b6b; }
    .badge.ok { background: #123a26; color: #7ee2ac; }
    .tranquilo { background: #121a14; border-left: 3px solid #4caf7d; padding: .6rem .8rem; border-radius: 6px; margin-top: 1rem; }
    .link-mini { font-size: .75rem; opacity: .7; }
  `],
})
export class AplicacoesComponent implements OnDestroy {
  private http = inject(HttpClient);

  trafego = signal<Trafego | null>(null);
  amostras = signal<Amostra[]>([]);
  projetos = signal<Projeto[]>([]);
  estado = signal<Estado | null>(null);
  minutos = signal(15);
  private timer: ReturnType<typeof setInterval>;

  constructor() {
    this.buscar();
    this.timer = setInterval(() => this.buscar(), 15000);
  }
  ngOnDestroy() { clearInterval(this.timer); }

  trocar(m: number) { this.minutos.set(m); this.buscar(); }

  buscar() {
    this.http.get<Trafego>(`/api/trafego?minutos=${this.minutos()}`).subscribe((t) => this.trafego.set(t));
    this.http.get<{ amostras: Amostra[] }>('/api/amostras?dias=2').subscribe((r) => this.amostras.set(r.amostras));
    this.http.get<Projeto[]>('/api/projetos').subscribe((p) => this.projetos.set(p));
    this.http.get<Estado>('/api/estado').subscribe((e) => this.estado.set(e));
  }

  semDados = computed(() => (this.trafego()?.total ?? 0) === 0);

  cartoes = computed(() => {
    const t = this.trafego();
    const projs = this.projetos();
    if (!t) return [];

    // parte da lista de PROJETOS, não do tráfego: aplicação sem movimento tem
    // que aparecer (quieta), senão some do painel justo quando alguém precisa
    // perguntar "por que ela não recebe nada?"
    return projs.map((p) => {
      const a = t.apps.find((x) => x.app === p.id);
      const rotas = (p.services ?? []).reduce((n, s) => n + (s.rotas?.length ?? 0), 0);
      return {
        app: p.id,
        nome: p.nome,
        rotas,
        total: a?.total ?? 0,
        bloqueadas: a?.bloqueadas ?? 0,
        erros: a?.erros ?? 0,
        mediaMs: a?.mediaMs ?? 0,
        barras: this.barrasDe(p.id),
      };
    }).sort((x, y) => y.total - x.total);
  });

  /** Últimas 30 amostras gravadas, normalizadas pelo pico da própria app. */
  private barrasDe(app: string) {
    const pontos = this.amostras()
      .slice(-30)
      .map((s) => s.apps?.find((x) => x.app === app))
      .map((x) => ({ total: x?.total ?? 0, bloq: (x?.bloqueadas ?? 0) > 0 }));
    const max = Math.max(1, ...pontos.map((p) => p.total));
    return pontos.map((p) => ({ h: Math.max(1, Math.round((p.total / max) * 26)), bloq: p.bloq }));
  }
}

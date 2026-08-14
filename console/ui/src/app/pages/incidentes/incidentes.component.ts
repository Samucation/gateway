import { Component, inject, signal } from '@angular/core';
import { CommonModule, DatePipe } from '@angular/common';
import { HttpClient } from '@angular/common/http';

interface Incidente {
  quando: string; nivel: 'alto' | 'medio'; ip: string; texto: string; apps?: string[];
}

/**
 * Histórico de incidentes.
 *
 * Lido de `console/dados/incidentes.jsonl`, gravado pelo vigia — e não do log
 * do Kong. O log do docker rotaciona e some junto com o container: sem o
 * arquivo, "relatório de incidentes" seria só a última hora, que não é
 * relatório nenhum.
 */
@Component({
  selector: 'gw-incidentes',
  standalone: true,
  imports: [CommonModule, DatePipe],
  template: `
    <h1 class="page-title">Incidentes</h1>
    <p class="page-sub">
      Sinais de abuso detectados pelo vigia, que relê a janela a cada 5 min mesmo com o console fechado.
    </p>

    <div class="toolbar">
      @for (d of [1, 7, 30, 90]; track d) {
        <button [class.ativo]="dias() === d" (click)="filtrar({ dias: d })">
          {{ d === 1 ? '24 h' : d + ' dias' }}
        </button>
      }
      <span style="width:1rem"></span>
      <button [class.ativo]="!nivel()" (click)="filtrar({ nivel: '' })">todos</button>
      <button [class.ativo]="nivel() === 'alto'" (click)="filtrar({ nivel: 'alto' })">só graves</button>
      <span class="grow"></span>
      <select [value]="app()" (change)="filtrar({ app: $any($event.target).value })">
        <option value="">todas as aplicações</option>
        @for (a of APPS; track a.id) { <option [value]="a.id">{{ a.nome }}</option> }
      </select>
    </div>

    @if (carregando()) { <div><span class="spinner"></span> Carregando...</div> }
    @else if (!lista().length) {
      <div class="tranquilo">
        Nenhum incidente no período. Isso é o normal — o vigia só registra quando um endereço
        cruza um dos limites (volume sustentado, bloqueios repetidos, 401/403 ou 404 em série).
      </div>
    }
    @else {
      <p class="page-sub">{{ total() }} incidente(s) no período.</p>
      <table>
        <thead><tr><th>Quando</th><th>Nível</th><th>Endereço</th><th>Aplicação</th><th>O que foi visto</th></tr></thead>
        <tbody>
          @for (i of lista(); track i.quando + i.ip + i.texto) {
            <tr [class.grave]="i.nivel === 'alto'">
              <td>{{ i.quando | date:'dd/MM HH:mm' }}</td>
              <td><span class="badge" [class.erro]="i.nivel === 'alto'">{{ i.nivel }}</span></td>
              <td><code>{{ i.ip }}</code></td>
              <td>@for (a of i.apps || []; track a) { <span class="badge muted">{{ nomeDaApp(a) }}</span> }</td>
              <td>{{ i.texto }}</td>
            </tr>
          }
        </tbody>
      </table>
    }
  `,
  styles: [`
    tr.grave { background: #1f141433; }
    .badge.erro { background: #3a1414; color: #ff9f9f; }
    .tranquilo { background: #121a14; border-left: 3px solid #4caf7d; padding: .7rem .9rem; border-radius: 6px; }
  `],
})
export class IncidentesComponent {
  private http = inject(HttpClient);

  readonly APPS = [
    { id: 'liveflow', nome: 'Urupix / live-flow' },
    { id: 'sigmafin', nome: 'Sigma Financeiro' },
    { id: 'plataforma', nome: 'Plataforma de Atendimento' },
    { id: 'central', nome: 'Central de IA' },
    { id: 'sigmapay', nome: 'Sigma Payments' },
  ];

  lista = signal<Incidente[]>([]);
  total = signal(0);
  dias = signal(7);
  nivel = signal('');
  app = signal('');
  carregando = signal(true);

  constructor() { this.buscar(); }

  filtrar(mudanca: { dias?: number; nivel?: string; app?: string }) {
    if (mudanca.dias !== undefined) this.dias.set(mudanca.dias);
    if (mudanca.nivel !== undefined) this.nivel.set(mudanca.nivel);
    if (mudanca.app !== undefined) this.app.set(mudanca.app);
    this.buscar();
  }

  buscar() {
    this.carregando.set(true);
    const q = new URLSearchParams({ dias: String(this.dias()) });
    if (this.nivel()) q.set('nivel', this.nivel());
    if (this.app()) q.set('app', this.app());
    this.http.get<{ total: number; incidentes: Incidente[] }>(`/api/incidentes?${q}`).subscribe({
      next: (r) => { this.lista.set(r.incidentes); this.total.set(r.total); this.carregando.set(false); },
      error: () => this.carregando.set(false),
    });
  }

  nomeDaApp(id: string) { return this.APPS.find((a) => a.id === id)?.nome ?? id; }
}

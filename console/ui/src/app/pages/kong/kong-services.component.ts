import { Component, inject, signal } from '@angular/core';
import { CommonModule, DatePipe } from '@angular/common';
import { KongApi, KongService } from '../../core/kong/kong.service';

@Component({
  selector: 'sigma-kong-services',
  standalone: true,
  imports: [CommonModule, DatePipe],
  template: `
    <h1 class="page-title">Kong · Services</h1>
    <p class="page-sub">Lista de upstreams configurados. Em DB-less, edições devem ser feitas em <code>infra/kong/kong.yml</code>.</p>

    <div class="toolbar">
      <input class="grow" type="text" placeholder="Filtrar por nome ou host..."
             [value]="filter()" (input)="setFilter($any($event.target).value)" />
      <button (click)="reload()">↻ Recarregar</button>
    </div>

    @if (loading()) { <div><span class="spinner"></span> Carregando services...</div> }
    @else if (error()) { <div class="error-box">{{ error() }}</div> }
    @else if (filtered().length === 0) { <div class="empty">Nenhum service encontrado.</div> }
    @else {
      <table>
        <thead>
          <tr><th>Nome</th><th>Protocolo</th><th>Host</th><th>Porta</th><th>Path</th><th>Timeouts (c/r/w)</th><th>Tags</th><th>Atualizado</th></tr>
        </thead>
        <tbody>
          @for (s of filtered(); track s.id) {
            <tr>
              <td><strong>{{ s.name }}</strong></td>
              <td><span class="badge">{{ s.protocol }}</span></td>
              <td><code>{{ s.host }}</code></td>
              <td>{{ s.port }}</td>
              <td>{{ s.path || '—' }}</td>
              <td><code>{{ s.connect_timeout }}/{{ s.read_timeout }}/{{ s.write_timeout }}ms</code></td>
              <td>
                @for (t of s.tags || []; track t) { <span class="badge muted">{{ t }}</span> }
              </td>
              <td>{{ s.updated_at * 1000 | date:'short' }}</td>
            </tr>
          }
        </tbody>
      </table>
    }
  `
})
export class KongServicesComponent {
  private api = inject(KongApi);
  loading = signal(true);
  error   = signal<string | null>(null);
  items   = signal<KongService[]>([]);
  filter  = signal('');

  constructor() { this.reload(); }

  setFilter(v: string) { this.filter.set(v); }

  filtered = () => {
    const f = this.filter().toLowerCase().trim();
    if (!f) return this.items();
    return this.items().filter(s =>
      s.name?.toLowerCase().includes(f) ||
      s.host?.toLowerCase().includes(f)
    );
  };

  reload(): void {
    this.loading.set(true);
    this.error.set(null);
    this.api.services().subscribe({
      next: r => { this.items.set(r.data || []); this.loading.set(false); },
      error: e => { this.error.set(e.message || 'Falha ao consultar Kong'); this.loading.set(false); }
    });
  }
}

import { Component, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { KongApi, KongPlugin } from '../../core/kong/kong.service';

@Component({
  selector: 'sigma-kong-plugins',
  standalone: true,
  imports: [CommonModule],
  template: `
    <h1 class="page-title">Kong · Plugins</h1>
    <p class="page-sub">Plugins globais e por-rota. Clique em "config" para inspecionar a configuração.</p>

    <div class="toolbar">
      <input class="grow" type="text" placeholder="Filtrar por nome do plugin..."
             [value]="filter()" (input)="setFilter($any($event.target).value)" />
      <button (click)="reload()">↻ Recarregar</button>
    </div>

    @if (loading()) { <div><span class="spinner"></span> Carregando plugins...</div> }
    @else if (error()) { <div class="error-box">{{ error() }}</div> }
    @else if (filtered().length === 0) { <div class="empty">Nenhum plugin configurado.</div> }
    @else {
      <table>
        <thead>
          <tr><th>Plugin</th><th>Escopo</th><th>Habilitado</th><th>Config</th></tr>
        </thead>
        <tbody>
          @for (p of filtered(); track p.id) {
            <tr>
              <td><strong>{{ p.name }}</strong></td>
              <td>
                @if (p.service?.id) { <span class="badge">service: {{ p.service?.id?.substring(0,8) }}</span> }
                @else if (p.route?.id) { <span class="badge">route: {{ p.route?.id?.substring(0,8) }}</span> }
                @else if (p.consumer?.id) { <span class="badge">consumer: {{ p.consumer?.id?.substring(0,8) }}</span> }
                @else { <span class="badge ok">global</span> }
              </td>
              <td>
                @if (p.enabled) { <span class="badge ok">ON</span> }
                @else { <span class="badge danger">OFF</span> }
              </td>
              <td>
                <button (click)="toggle(p.id)">{{ expanded() === p.id ? 'Ocultar' : 'Ver config' }}</button>
                @if (expanded() === p.id) {
                  <pre>{{ p.config | json }}</pre>
                }
              </td>
            </tr>
          }
        </tbody>
      </table>
    }
  `
})
export class KongPluginsComponent {
  private api = inject(KongApi);
  loading = signal(true);
  error   = signal<string | null>(null);
  items   = signal<KongPlugin[]>([]);
  filter  = signal('');
  expanded = signal<string | null>(null);

  constructor() { this.reload(); }

  setFilter(v: string) { this.filter.set(v); }
  toggle(id: string) { this.expanded.set(this.expanded() === id ? null : id); }

  filtered = () => {
    const f = this.filter().toLowerCase().trim();
    if (!f) return this.items();
    return this.items().filter(p => p.name.toLowerCase().includes(f));
  };

  reload(): void {
    this.loading.set(true); this.error.set(null);
    this.api.plugins().subscribe({
      next: r => { this.items.set(r.data || []); this.loading.set(false); },
      error: e => { this.error.set(e.message || 'Falha'); this.loading.set(false); }
    });
  }
}

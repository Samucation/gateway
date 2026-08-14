import { Component, computed, inject, signal } from '@angular/core';
import { CommonModule, DatePipe } from '@angular/common';
import { forkJoin } from 'rxjs';
import { KongApi, KongRoute, KongService } from '../../core/kong/kong.service';

@Component({
  selector: 'sigma-kong-routes',
  standalone: true,
  imports: [CommonModule, DatePipe],
  template: `
    <h1 class="page-title">Kong · Routes</h1>
    <p class="page-sub">Caminhos expostos pelo gateway. Os métodos e paths refletem o YAML carregado.</p>

    <div class="toolbar">
      <input class="grow" type="text" placeholder="Filtrar por nome, path ou método..."
             [value]="filter()" (input)="setFilter($any($event.target).value)" />
      <button (click)="reload()">↻ Recarregar</button>
    </div>

    @if (loading()) { <div><span class="spinner"></span> Carregando routes...</div> }
    @else if (error()) { <div class="error-box">{{ error() }}</div> }
    @else if (filtered().length === 0) { <div class="empty">Nenhum route encontrado.</div> }
    @else {
      <table>
        <thead>
          <tr><th>Nome</th><th>Métodos</th><th>Paths</th><th>Service</th><th>Strip path</th><th>Tags</th><th>Atualizado</th></tr>
        </thead>
        <tbody>
          @for (r of filtered(); track r.id) {
            <tr>
              <td><strong>{{ r.name || r.id.substring(0,8) }}</strong></td>
              <td>
                @for (m of r.methods || []; track m) {
                  <span class="pill" [class.get]="m==='GET'" [class.post]="m==='POST'" [class.put]="m==='PUT'" [class.delete]="m==='DELETE'" [class.patch]="m==='PATCH'">{{ m }}</span>
                }
              </td>
              <td>
                @for (p of r.paths || []; track p) {
                  <div><code>{{ p }}</code></div>
                }
              </td>
              <td>{{ serviceName(r.service?.id) }}</td>
              <td>{{ r.strip_path ? 'yes' : 'no' }}</td>
              <td>
                @for (t of r.tags || []; track t) { <span class="badge muted">{{ t }}</span> }
              </td>
              <td>{{ r.updated_at * 1000 | date:'short' }}</td>
            </tr>
          }
        </tbody>
      </table>
    }
  `
})
export class KongRoutesComponent {
  private api = inject(KongApi);
  loading = signal(true);
  error   = signal<string | null>(null);
  routes  = signal<KongRoute[]>([]);
  services = signal<KongService[]>([]);
  filter  = signal('');

  constructor() { this.reload(); }

  setFilter(v: string) { this.filter.set(v); }

  serviceName(id?: string): string {
    if (!id) return '—';
    return this.services().find(s => s.id === id)?.name ?? id.substring(0, 8);
  }

  filtered = computed(() => {
    const f = this.filter().toLowerCase().trim();
    if (!f) return this.routes();
    return this.routes().filter(r =>
      (r.name?.toLowerCase().includes(f)) ||
      (r.paths || []).some(p => p.toLowerCase().includes(f)) ||
      (r.methods || []).some(m => m.toLowerCase().includes(f))
    );
  });

  reload(): void {
    this.loading.set(true); this.error.set(null);
    forkJoin({ r: this.api.routes(), s: this.api.services() }).subscribe({
      next: ({ r, s }) => {
        this.routes.set(r.data || []);
        this.services.set(s.data || []);
        this.loading.set(false);
      },
      error: e => { this.error.set(e.message || 'Falha ao consultar Kong'); this.loading.set(false); }
    });
  }
}

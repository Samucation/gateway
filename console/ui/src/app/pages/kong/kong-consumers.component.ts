import { Component, inject, signal } from '@angular/core';
import { CommonModule, DatePipe } from '@angular/common';
import { KongApi, KongConsumer } from '../../core/kong/kong.service';

@Component({
  selector: 'sigma-kong-consumers',
  standalone: true,
  imports: [CommonModule, DatePipe],
  template: `
    <h1 class="page-title">Kong · Consumers</h1>
    <p class="page-sub">Identidades conhecidas pelo gateway. Como o Sigma valida JWT no Spring (não no Kong), essa lista normalmente fica vazia neste setup.</p>

    @if (loading()) { <div><span class="spinner"></span> Carregando consumers...</div> }
    @else if (error()) { <div class="error-box">{{ error() }}</div> }
    @else if (items().length === 0) {
      <div class="empty">
        Nenhum consumer cadastrado no Kong. <br/>
        <span class="sub">A autenticação fim a fim é feita pelo Spring Security + Keycloak — ver <strong>Keycloak · Realm</strong>.</span>
      </div>
    } @else {
      <table>
        <thead><tr><th>Username</th><th>Custom ID</th><th>Tags</th><th>Criado em</th></tr></thead>
        <tbody>
          @for (c of items(); track c.id) {
            <tr>
              <td><strong>{{ c.username || '—' }}</strong></td>
              <td>{{ c.custom_id || '—' }}</td>
              <td>
                @for (t of c.tags || []; track t) { <span class="badge muted">{{ t }}</span> }
              </td>
              <td>{{ c.created_at * 1000 | date:'short' }}</td>
            </tr>
          }
        </tbody>
      </table>
    }
  `
})
export class KongConsumersComponent {
  private api = inject(KongApi);
  loading = signal(true);
  error   = signal<string | null>(null);
  items   = signal<KongConsumer[]>([]);

  constructor() {
    this.api.consumers().subscribe({
      next: r => { this.items.set(r.data || []); this.loading.set(false); },
      error: e => { this.error.set(e.message || 'Falha'); this.loading.set(false); }
    });
  }
}

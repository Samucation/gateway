import { Component, inject, signal } from '@angular/core';
import { CommonModule, DatePipe } from '@angular/common';
import { KongApi, KongUpstream } from '../../core/kong/kong.service';

@Component({
  selector: 'sigma-kong-upstreams',
  standalone: true,
  imports: [CommonModule, DatePipe],
  template: `
    <h1 class="page-title">Kong · Upstreams</h1>
    <p class="page-sub">Conjuntos de targets balanceados pelo Kong. Vazio se cada service aponta direto para uma URL fixa (caso deste projeto).</p>

    @if (loading()) { <div><span class="spinner"></span> Carregando upstreams...</div> }
    @else if (error()) { <div class="error-box">{{ error() }}</div> }
    @else if (items().length === 0) {
      <div class="empty">Nenhum upstream configurado. Os services apontam diretamente para <code>http://app:8080</code>.</div>
    } @else {
      <table>
        <thead><tr><th>Nome</th><th>Algorithm</th><th>Slots</th><th>Hash on</th><th>Criado em</th></tr></thead>
        <tbody>
          @for (u of items(); track u.id) {
            <tr>
              <td><strong>{{ u.name }}</strong></td>
              <td><span class="badge">{{ u.algorithm }}</span></td>
              <td>{{ u.slots }}</td>
              <td>{{ u.hash_on || '—' }}</td>
              <td>{{ u.created_at * 1000 | date:'short' }}</td>
            </tr>
          }
        </tbody>
      </table>
    }
  `
})
export class KongUpstreamsComponent {
  private api = inject(KongApi);
  loading = signal(true);
  error   = signal<string | null>(null);
  items   = signal<KongUpstream[]>([]);

  constructor() {
    this.api.upstreams().subscribe({
      next: r => { this.items.set(r.data || []); this.loading.set(false); },
      error: e => { this.error.set(e.message || 'Falha'); this.loading.set(false); }
    });
  }
}

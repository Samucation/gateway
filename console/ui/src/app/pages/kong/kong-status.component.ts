import { Component, computed, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { catchError, of } from 'rxjs';
import { environment } from '../../../environments/environment';
import { KongApi, KongInfo } from '../../core/kong/kong.service';

interface KongStatus {
  memory?: {
    lua_shared_dicts?: Record<string, { allocated_slabs?: string; capacity?: string }>;
    workers_lua_vms?: Array<{ http_allocated_gc?: string; pid?: number }>;
  };
  server?: {
    total_requests?: number;
    connections_active?: number;
    connections_accepted?: number;
    connections_handled?: number;
    connections_reading?: number;
    connections_writing?: number;
    connections_waiting?: number;
  };
  database?: { reachable?: boolean };
  configuration_hash?: string;
}

@Component({
  selector: 'sigma-kong-status',
  standalone: true,
  imports: [CommonModule],
  template: `
    <h1 class="page-title">Kong · Status</h1>
    <p class="page-sub">Estado interno do gateway. Atualiza a cada 10s.</p>

    @if (errInfo() || errStatus()) {
      <div class="error-box" style="margin-bottom:18px">
        @if (errInfo())   { <div>Info: {{ errInfo() }}</div> }
        @if (errStatus()) { <div>Status: {{ errStatus() }}</div> }
      </div>
    }

    <!-- ===== Identificação ===== -->
    <h3 class="section-title">Identificação</h3>
    <div class="grid-4">
      <div class="kpi">
        <div class="kpi-label">Versão</div>
        <div class="kpi-value">{{ info()?.version || '—' }}</div>
        <div class="kpi-sub">{{ info()?.tagline || 'Kong Gateway' }}</div>
      </div>
      <div class="kpi">
        <div class="kpi-label">Hostname</div>
        <div class="kpi-value mono">{{ info()?.hostname || '—' }}</div>
        <div class="kpi-sub">node ID</div>
      </div>
      <div class="kpi">
        <div class="kpi-label">Plugins habilitados</div>
        <div class="kpi-value">{{ pluginsCount() }}</div>
        <div class="kpi-sub">no cluster</div>
      </div>
      <div class="kpi">
        <div class="kpi-label">Configuration hash</div>
        <div class="kpi-value mono small">{{ confHash() }}</div>
        <div class="kpi-sub">SHA do kong.yml carregado</div>
      </div>
    </div>

    <!-- ===== Conexões NGINX ===== -->
    <h3 class="section-title">Conexões NGINX</h3>
    <div class="grid-4">
      <div class="kpi accent">
        <div class="kpi-label">Ativas</div>
        <div class="kpi-value">{{ status()?.server?.connections_active ?? '—' }}</div>
        <div class="kpi-sub">handshakes incluídos</div>
      </div>
      <div class="kpi">
        <div class="kpi-label">Reading</div>
        <div class="kpi-value">{{ status()?.server?.connections_reading ?? '—' }}</div>
        <div class="kpi-sub">lendo request header</div>
      </div>
      <div class="kpi">
        <div class="kpi-label">Writing</div>
        <div class="kpi-value">{{ status()?.server?.connections_writing ?? '—' }}</div>
        <div class="kpi-sub">enviando response</div>
      </div>
      <div class="kpi">
        <div class="kpi-label">Waiting</div>
        <div class="kpi-value">{{ status()?.server?.connections_waiting ?? '—' }}</div>
        <div class="kpi-sub">keep-alive idle</div>
      </div>
    </div>

    <h3 class="section-title">Throughput</h3>
    <div class="grid-3">
      <div class="kpi">
        <div class="kpi-label">Requests totais</div>
        <div class="kpi-value">{{ fmt(status()?.server?.total_requests) }}</div>
        <div class="kpi-sub">desde o boot do worker</div>
      </div>
      <div class="kpi">
        <div class="kpi-label">Conexões aceitas</div>
        <div class="kpi-value">{{ fmt(status()?.server?.connections_accepted) }}</div>
        <div class="kpi-sub">total acumulado</div>
      </div>
      <div class="kpi">
        <div class="kpi-label">Conexões tratadas</div>
        <div class="kpi-value">{{ fmt(status()?.server?.connections_handled) }}</div>
        <div class="kpi-sub">
          @if (droppedConnections() > 0) { <span class="badge danger">{{ droppedConnections() }} dropadas</span> }
          @else { <span class="badge ok">0 dropadas</span> }
        </div>
      </div>
    </div>

    <!-- ===== Database (proxy-side) ===== -->
    <h3 class="section-title">Database</h3>
    <div class="grid-3">
      <div class="kpi">
        <div class="kpi-label">Modo</div>
        <div class="kpi-value">DB-less</div>
        <div class="kpi-sub">config é o YAML</div>
      </div>
      <div class="kpi">
        <div class="kpi-label">Reachable</div>
        <div class="kpi-value">
          @if (status()?.database?.reachable === true) { <span class="badge ok">YES</span> }
          @else if (status()?.database?.reachable === false) { <span class="badge danger">NO</span> }
          @else { <span class="badge muted">N/A</span> }
        </div>
        <div class="kpi-sub">em DB-less é meramente informativo</div>
      </div>
      <div class="kpi">
        <div class="kpi-label">Workers</div>
        <div class="kpi-value">{{ workersCount() }}</div>
        <div class="kpi-sub">processos nginx</div>
      </div>
    </div>

    <!-- ===== Memória ===== -->
    @if (sharedDictsList().length > 0) {
      <h3 class="section-title">Lua shared dicts</h3>
      <table>
        <thead><tr><th>Dict</th><th>Allocated</th><th>Capacity</th><th>% uso</th></tr></thead>
        <tbody>
          @for (d of sharedDictsList(); track d.name) {
            <tr>
              <td><code>{{ d.name }}</code></td>
              <td>{{ d.allocated }}</td>
              <td>{{ d.capacity }}</td>
              <td>
                <div class="bar">
                  <div class="bar-fill" [style.width.%]="d.pct"
                       [class.warn]="d.pct >= 60 && d.pct < 85"
                       [class.danger]="d.pct >= 85"></div>
                </div>
                <small class="kpi-sub">{{ d.pct }}%</small>
              </td>
            </tr>
          }
        </tbody>
      </table>
    }

    @if (workers().length > 0) {
      <h3 class="section-title">Workers</h3>
      <table>
        <thead><tr><th>PID</th><th>HTTP allocated GC (Lua)</th></tr></thead>
        <tbody>
          @for (w of workers(); track w.pid) {
            <tr>
              <td><code>{{ w.pid }}</code></td>
              <td>{{ w.http_allocated_gc || '—' }}</td>
            </tr>
          }
        </tbody>
      </table>
    }

    <h3 class="section-title">Plugins habilitados</h3>
    @if (info()) {
      <div class="chip-row">
        @for (p of (info()?.plugins?.enabled_in_cluster || []); track p) {
          <span class="badge ok">{{ p }}</span>
        }
      </div>
    } @else { <div class="empty">Carregando...</div> }

    <hr class="section-divider"/>
    <button (click)="reload()">↻ Atualizar agora</button>
  `,
  styles: [`
    .section-title {
      margin: 28px 0 12px 0; color: var(--text-muted); font-size: 11px;
      letter-spacing: 0.08em; text-transform: uppercase; font-weight: 700;
    }
    .kpi {
      background: var(--panel); border: 1px solid var(--border); border-radius: 10px;
      padding: 16px 18px; display: flex; flex-direction: column; gap: 6px;
    }
    .kpi.accent { border-color: rgba(76,139,245,0.45); background: linear-gradient(135deg, rgba(76,139,245,0.10), var(--panel)); }
    .kpi-label { font-size: 11px; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.05em; font-weight: 600; }
    .kpi-value { font-size: 28px; font-weight: 700; line-height: 1.1; color: var(--text); }
    .kpi-value.small { font-size: 14px; }
    .kpi-value.mono { font-family: 'JetBrains Mono', Consolas, monospace; }
    .kpi-sub { font-size: 12px; color: var(--text-muted); }
    .bar { height: 6px; background: var(--bg-elev); border-radius: 3px; overflow: hidden; margin-bottom: 4px; }
    .bar-fill { height: 100%; background: linear-gradient(90deg, #4c8bf5, #6ba0ff); transition: width .3s ease; }
    .bar-fill.warn { background: linear-gradient(90deg, #f1a83a, #f7c66c); }
    .bar-fill.danger { background: linear-gradient(90deg, #e5484d, #ff6b6f); }
    .chip-row { display: flex; flex-wrap: wrap; gap: 6px; }
  `]
})
export class KongStatusComponent {
  private api = inject(KongApi);
  private http = inject(HttpClient);

  info     = signal<KongInfo | null>(null);
  status   = signal<KongStatus | null>(null);
  errInfo  = signal<string | null>(null);
  errStatus = signal<string | null>(null);

  pluginsCount = () => this.info()?.plugins?.enabled_in_cluster?.length ?? 0;
  confHash     = () => {
    const h = this.status()?.configuration_hash;
    if (!h) return '—';
    return h.length > 16 ? `${h.substring(0, 8)}…${h.substring(h.length - 6)}` : h;
  };
  droppedConnections = () => {
    const accepted = this.status()?.server?.connections_accepted ?? 0;
    const handled = this.status()?.server?.connections_handled ?? 0;
    return Math.max(0, accepted - handled);
  };
  workers = () => this.status()?.memory?.workers_lua_vms ?? [];
  workersCount = () => this.workers().length;

  sharedDictsList = computed(() => {
    const dicts = this.status()?.memory?.lua_shared_dicts ?? {};
    return Object.entries(dicts).map(([name, v]) => {
      const allocated = v.allocated_slabs || '0';
      const capacity = v.capacity || '0';
      const aBytes = parseBytes(allocated);
      const cBytes = parseBytes(capacity);
      const pct = cBytes > 0 ? Math.round((aBytes / cBytes) * 100) : 0;
      return { name, allocated, capacity, pct };
    }).sort((a, b) => b.pct - a.pct);
  });

  fmt(n?: number): string {
    if (n == null) return '—';
    return new Intl.NumberFormat('pt-BR').format(n);
  }

  constructor() {
    this.reload();
    setInterval(() => this.reload(), 10000);
  }

  reload(): void {
    this.api.info().pipe(catchError(e => { this.errInfo.set(e.message || 'Falha'); return of(null); }))
      .subscribe(i => { if (i) { this.info.set(i); this.errInfo.set(null); } });

    this.http.get<KongStatus>(`${environment.api.kongStatus}/status`).pipe(
      catchError(e => { this.errStatus.set(e.message || 'Falha'); return of(null); })
    ).subscribe(s => { if (s) { this.status.set(s); this.errStatus.set(null); } });
  }
}

function parseBytes(s: string): number {
  if (!s) return 0;
  const m = s.match(/^([\d.]+)\s*([KMGT]?)i?B?$/i);
  if (!m) return Number(s) || 0;
  const n = parseFloat(m[1]);
  const unit = (m[2] || '').toUpperCase();
  const mul: Record<string, number> = { '': 1, K: 1024, M: 1024 ** 2, G: 1024 ** 3, T: 1024 ** 4 };
  return n * (mul[unit] ?? 1);
}

import { Component } from '@angular/core';
import { RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';
import { CommonModule } from '@angular/common';

/**
 * Casca do console do gateway.
 *
 * Veio do `sigma-payments-ops-ui`, sem o seletor de aplicacao, o cartao de
 * usuario e os links de Iugu/Keycloak/Sigma: aqueles dependiam do AuthService e
 * do AppsService, que este console nao usa (ver app.config.ts). Os ESTILOS
 * foram preservados inteiros.
 */
@Component({
  selector: 'gw-shell',
  standalone: true,
  imports: [CommonModule, RouterLink, RouterLinkActive, RouterOutlet],
  template: `
    <div class="layout">
      <aside class="sidebar">
        <div class="brand">
          <span class="logo">&#9961;</span>
          <div>
            <div class="brand-title">Gateway</div>
            <div class="brand-sub">um Kong para os 5 projetos</div>
          </div>
        </div>

        <nav>
          <div class="nav-group">Configuracao</div>
          <a routerLink="/projetos" routerLinkActive="active">Projetos (editar)</a>

          <div class="nav-group">No ar agora</div>
          <a routerLink="/kong/services"  routerLinkActive="active">Services</a>
          <a routerLink="/kong/routes"    routerLinkActive="active">Routes</a>
          <a routerLink="/kong/plugins"   routerLinkActive="active">Plugins</a>
          <a routerLink="/kong/consumers" routerLinkActive="active">Consumers</a>
          <a routerLink="/kong/upstreams" routerLinkActive="active">Upstreams</a>
          <a routerLink="/kong/status"    routerLinkActive="active">Status</a>

        </nav>
      </aside>

      <main class="main">
        <div class="callout-warn">
          As telas de <strong>No ar agora</strong> leem a Admin API e sao somente leitura &mdash; em
          DB-less o Kong recusa criar entidade por API. Para mudar algo, use
          <a routerLink="/projetos">Projetos</a>.
        </div>
        <router-outlet />
      </main>
    </div>
  `,
  styles: [`
    .layout { display: grid; grid-template-columns: 260px 1fr; min-height: 100vh; }
    .sidebar {
      background: var(--bg-elev); border-right: 1px solid var(--border);
      display: flex; flex-direction: column; padding: 20px 0;
      position: sticky; top: 0; height: 100vh; overflow-y: auto;
    }
    .brand { display: flex; align-items: center; gap: 12px; padding: 0 22px 22px 22px; border-bottom: 1px solid var(--border); margin-bottom: 14px; }
    .logo { background: linear-gradient(135deg, #4c8bf5, #6ba0ff); color: white; width: 38px; height: 38px; display: grid; place-items: center; border-radius: 8px; font-size: 22px; font-weight: 700; }
    .brand-title { font-weight: 700; font-size: 15px; }
    .brand-sub { font-size: 11px; color: var(--text-muted); margin-top: 2px; }

    .app-selector { padding: 0 16px 14px 16px; border-bottom: 1px solid var(--border); margin-bottom: 10px; }
    .app-selector label { display: block; font-size: 10px; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.07em; font-weight: 600; margin-bottom: 6px; }
    .app-selector select { width: 100%; padding: 6px 8px; font-size: 13px; }
    .app-selector .empty-mini { font-size: 12px; color: var(--text-muted); padding: 4px 0; }
    .app-selector .link-mini { display: block; font-size: 11px; margin-top: 6px; color: var(--accent-2); }

    nav { flex: 1; padding: 0 12px; }
    .nav-group { font-size: 10px; text-transform: uppercase; letter-spacing: 0.08em; color: var(--text-muted); padding: 14px 12px 6px 12px; font-weight: 700; }
    nav a {
      display: block; padding: 7px 12px; border-radius: 6px; color: var(--text);
      font-size: 13.5px; margin: 1px 0; text-decoration: none;
    }
    nav a:hover { background: var(--panel-2); text-decoration: none; }
    nav a.active { background: var(--accent-soft); color: var(--accent-2); font-weight: 600; }

    .user-card { padding: 14px 18px; border-top: 1px solid var(--border); margin-top: 8px; }
    .user-name { font-weight: 600; }
    .user-email { font-size: 12px; color: var(--text-muted); margin-top: 2px; }
    .user-roles { margin-top: 8px; display: flex; flex-wrap: wrap; gap: 4px; }
    .user-roles .badge { font-size: 10px; padding: 1px 6px; }
    .user-actions { display: flex; gap: 6px; margin-top: 10px; }
    .user-actions button { flex: 1; font-size: 12px; padding: 5px 10px; }

    .main { padding: 28px 36px; min-width: 0; }

    .active-banner {
      background: var(--panel); border: 1px solid var(--border); border-left: 4px solid var(--accent);
      padding: 8px 14px; border-radius: 6px; margin-bottom: 18px; font-size: 12px;
      color: var(--text-muted); display: flex; align-items: center; gap: 10px;
    }
    .active-banner strong { color: var(--text); }
    .active-banner .dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block; }
    .active-banner .mini { font-size: 11px; margin-left: auto; }

    .callout-warn { background: rgba(241,168,58,0.10); border: 1px solid rgba(241,168,58,0.35); padding: 10px 14px; border-radius: 6px; margin-bottom: 18px; color: #f1a83a; }
    .callout-warn a { color: #f7c66c; font-weight: 600; }

    @media (max-width: 900px) {
      .layout { grid-template-columns: 1fr; }
      .sidebar { position: relative; height: auto; }
      .main { padding: 18px; }
    }
  `]
})
export class ShellComponent {}

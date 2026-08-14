import { bootstrapApplication } from '@angular/platform-browser';
import { AppComponent } from './app/app.component';
import { appConfig } from './app/app.config';

bootstrapApplication(AppComponent, appConfig).catch(err => {
  console.error('Failed to bootstrap', err);
  document.body.innerHTML = `
    <div style="font-family:sans-serif;padding:40px;color:#9b2c2c;background:#fff">
      <h2>Falha ao iniciar a Ops UI</h2>
      <pre style="background:#fde2e2;padding:12px;border-radius:6px;white-space:pre-wrap">${(err as Error).message ?? err}</pre>
      <p>Verifique se o Keycloak está acessível em <code>http://localhost:8089</code> e se o realm <code>sigma</code> foi importado com o client <code>sigma-ops-ui</code>.</p>
    </div>`;
});

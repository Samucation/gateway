import { ApplicationConfig, provideZoneChangeDetection } from '@angular/core';
import { provideRouter } from '@angular/router';
import { provideHttpClient } from '@angular/common/http';
import { routes } from './app.routes';

/**
 * Sem Keycloak e sem catálogo de apps.
 *
 * A base veio do `sigma-payments-ops-ui`, que faz login por Keycloak porque é
 * exposto. Este console é servido só em 127.0.0.1 (ver console/servidor.mjs), e
 * um login aqui protegeria de quem já pode editar os arquivos direto — custo
 * sem defesa. Se o console sair do loopback um dia, a autenticação volta ANTES
 * de abrir a porta.
 *
 * O `provideAppInitializer` do Keycloak era BLOQUEANTE: mantê-lo deixaria a
 * tela em branco para sempre, esperando um servidor que não é usado aqui.
 */
export const appConfig: ApplicationConfig = {
  providers: [
    provideZoneChangeDetection({ eventCoalescing: true }),
    provideRouter(routes),
    provideHttpClient(),
  ],
};

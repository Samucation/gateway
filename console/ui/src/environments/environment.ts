// Em dev (ng serve) os paths /api/* são proxiados pelo angular CLI.
// Em produção (nginx) os mesmos paths são proxiados pelo nginx.
// Mantemos os defaults pensando no compose; podem ser sobrescritos em runtime
// via /assets/runtime-config.json se necessário.
export const environment = {
  production: false,
  keycloak: {
    url: 'http://localhost:8089',
    realm: 'sigma',
    clientId: 'sigma-ops-ui'
  },
  api: {
    kong:     '/api/kong',
    kongStatus: '/api/kong-status',
    app:      '/api/app',
    prom:     '/api/prom',
    keycloak: '/api/keycloak-admin',
    opsApi:   '/api/ops'
  }
};

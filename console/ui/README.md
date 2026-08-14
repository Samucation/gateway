# Sigma Ops UI

Angular 18 SPA que substitui o Kong Manager (que é Enterprise-only) e
adiciona painéis para o Sigma Payments, o adapter Iugu e o realm Keycloak.

## Endpoints visualizados

| Painel | Origem dos dados |
|---|---|
| Dashboard | Kong admin API + `/actuator/health` + Prometheus |
| Kong → Services / Routes / Plugins / Consumers / Upstreams / Status | `http://kong:8001` (admin) e `http://kong:8100` (status) |
| Sigma → Health | `http://app:8080/actuator/health` |
| Sigma → Métricas | Prometheus (`http://prometheus:9090/api/v1/query`) |
| Iugu → Visão geral | Prometheus + `/actuator/health` |
| Keycloak → Realm | `.well-known/openid-configuration` + console admin |

## Login

Via Keycloak (realm `sigma`, client `sigma-ops-ui`, PKCE S256).

Usuários sementes no `infra/keycloak/sigma-realm.json`:

| User | Senha | Roles |
|---|---|---|
| `opsadmin` | `opsadmin` | `ADMIN`, `PAYMENTS_READ`, `PAYMENTS_WRITE` |
| `opsviewer` | `opsviewer` | `PAYMENTS_READ` |

## Dev local

```bash
cd sigma-payments-ops-ui
npm install
npm start        # http://localhost:4200
```

O `proxy.conf.json` aponta os `/api/*` para os hosts locais expostos (Kong em 8001, app em 8080, Prometheus em 9090, Keycloak em 8089).

## Produção (compose)

```bash
docker compose up -d ops-ui
# abrir http://localhost:8090
```

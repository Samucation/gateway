# Mapeamento dos Kongs — o que existe hoje

Levantado em 14/08/2026 varrendo os containers ativos no Docker.

## Os cinco gateways

| Container | Projeto | Porta pública | Memória | Config |
|---|---|---:|---:|---|
| `liveflow-kong` | live-flow | **8000** | 2,20 GB | `live-flow/deploy/kong/kong.yml` |
| `sigma-kong` | sigma-financeiro | **8010** | 2,16 GB | `sigma-financeiro/deploy/kong/kong.yml` |
| `plataforma-kong` | cafe-mobile-erp | **8020** | 189 MB | `cafe-mobile-erp/kong/kong.yml` |
| `central-kong` | central-ia | **8030** | 199 MB | `central-ia/deploy/kong/kong.yml` |
| *(não sobe)* | sigma-payments | — | — | `sigma-payments/infra/kong/kong.yml` |

**4,75 GB** somados. Unificar libera ~2,2 GB — o peso está nos dois primeiros,
que rodam sem teto de memória e sobem 32 workers cada.

## Os 12 serviços

| Projeto | Services | Upstream |
|---|---|---|
| live-flow | `liveflow-sse`, `liveflow-app` | `host.docker.internal:3100` (o Next roda na MÁQUINA, não em container) |
| sigma-financeiro | `sigma-app` | `host.docker.internal` |
| central-ia | `central-transcricao`, `central-voz`, `central-conversa`, `central-saude`, `central-portal` | rede `central-ia_default` (`motor`, `portal`) |
| cafe-mobile-erp | `plataforma-api`, `plataforma-webhooks`, `plataforma-web` | rede `cafe-mobile-erp_default` (`plataforma-app`) |
| sigma-payments | `sigma-payments` | rede própria (`app`) |

Dois falam com a máquina, três falam com redes internas — o Kong único precisa
estar **em todas as redes** e manter `extra_hosts: host-gateway`.

## ⚠️ O achado que decide o projeto: 7 caminhos colidem

**Nenhuma rota, em nenhum dos cinco, declara `hosts:`.** Faz sentido hoje: cada
Kong atende UM projeto na porta dele, então o caminho basta para desambiguar.

Num Kong só isso deixa de valer:

| Caminho | Disputado por |
|---|---|
| `/` | central-ia, live-flow, sigma-financeiro |
| `/admin` | central-ia, live-flow, sigma-financeiro |
| `/api/admin` | central-ia, live-flow, sigma-financeiro |
| `/api/portal` | central-ia, sigma-financeiro |
| `/api/webhooks` | live-flow, sigma-financeiro |
| `/_next` | live-flow, sigma-financeiro |
| `/favicon.ico` | live-flow, sigma-financeiro |

Sem `hosts:`, o Kong casa pela ordem/prioridade e entrega **a página do projeto
errado** — sem erro nenhum no log, porque do ponto de vista dele a rota casou.
`/api/webhooks` é o pior caso: webhook de pagamento do Sigma cairia no live-flow.

**Portanto a migração não é copiar e colar.** Cada rota precisa ganhar o
`hosts:` do domínio que já a atende hoje:

| Projeto | Hosts a declarar |
|---|---|
| live-flow | `urupix.com.br`, `www.urupix.com.br`, `urupix.cursodetecnologia.dev.br` |
| sigma-financeiro | `sigma-financeiro.cursodetecnologia.dev.br` |
| cafe-mobile-erp | `cafe-api.cursodetecnologia.dev.br` |
| central-ia | *(sem domínio público hoje — só porta local)* |
| sigma-payments | *(sem domínio público hoje)* |

## Plugins

`correlation-id`, `cors` e `prometheus` estão nos **cinco** — viram globais.
Ficam por rota os que variam: `rate-limiting` (limites diferentes por serviço),
`ip-restriction` (só cafe-mobile-erp), `request/response-transformer`.

Atenção ao `rate-limiting` do `liveflow-sse`: 600/min e `read_timeout` de 1 h,
porque overlay de OBS é conexão aberta por horas. Copiar o limite padrão para
essa rota derruba live legítima.

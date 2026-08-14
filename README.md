# gateway — um Kong para todo o ambiente

Hoje existem **cinco** Kongs, um por projeto, somando **4,75 GB**. Este projeto
substitui todos por um só, com a configuração de todos centralizada aqui.

O motivo não é organização: o Docker vinha **caindo por pressão de memória** e
derrubando o Urupix junto, no meio de live. Os dois maiores Kongs sobem 32
workers cada e rodam sem teto.

## Estado: fundação pronta, nada cortado ainda

| Etapa | |
|---|---|
| Mapear os 5 Kongs | ✅ [`docs/mapeamento.md`](docs/mapeamento.md) |
| Gerador da config unificada | ✅ `scripts/gerar-kong.mjs` |
| Config unificada (12 services, 44 rotas) | ✅ `kong/kong.yml` — `kong config parse` aprova |
| Compose do Kong único | ✅ porta **8040**, ao lado dos atuais |
| Subir e comparar rota a rota | ⏳ |
| Frontend de operação | ⏳ vem do `sigma-payments-ops-ui` |
| Cortar os Kongs locais | ⏳ um por vez, no fim |

**Nada foi desligado.** O Kong novo nasce na 8040 para conviver com os antigos;
só assume a 8000 quando cada rota estiver provada.

## O achado que definiu o desenho

Os cinco Kongs de hoje **não declaram `hosts:` em nenhuma rota** — cada um
atende um projeto na porta dele, então o caminho basta.

Num Kong só isso quebra: **sete caminhos são disputados** por dois ou três
projetos — `/`, `/admin`, `/api/admin`, `/api/portal`, `/api/webhooks`,
`/_next`, `/favicon.ico`. Sem host, o Kong casa por prioridade e entrega **a
página do projeto errado, sem erro no log**. `/api/webhooks` é o pior: webhook
de pagamento do Sigma cairia no live-flow.

Por isso o gerador **injeta `hosts:` em toda rota** e **reprova** se dois
projetos reivindicarem o mesmo host+caminho. Hoje `/` resolve para quatro
serviços diferentes, cada um pelo seu domínio.

## Por que um gerador, e não uma cópia

Durante a transição os projetos continuam vivos e mexendo nos próprios
gateways. Cópia manual nasce desatualizada na primeira rota nova, e a
divergência aparece como *"funciona no Kong antigo e some no novo"*.

```bash
npm install
npm run gerar     # relê os 5 kong.yml e regenera kong/kong.yml
```

Para mudar uma rota, mude **no projeto** e rode o gerador. `kong/kong.yml` é
gerado — editar à mão faz a mudança sumir na próxima geração.

## De onde vem a economia

| | |
|---|---|
| 5 Kongs hoje | 4,75 GB |
| 1 Kong com `KONG_NGINX_WORKER_PROCESSES=2` e `mem_limit: 512m` | ~250 MB |

Os 32 workers por Kong são o padrão (um por núcleo). Para 5 apps domésticos,
2 workers atendem de sobra.

## Ordem do corte (do menor risco para o maior)

1. `central-ia` — sem domínio público
2. `cafe-mobile-erp` — API interna
3. `sigma-financeiro`
4. `live-flow` — **por último**: é o que tem live em produção

Cada corte: apontar o túnel para a 8040 → conferir → remover o Kong local.
Reverter é reapontar o túnel de volta.

## Frontend

O console de operação virá do **`sigma-payments/sigma-payments-ops-ui`**
(Angular), que já tem páginas de services, routes, consumers, plugins,
upstreams e status, além de Prometheus, Keycloak e alertas. É a base mais
completa do workspace — bem mais que o painel de leitura do live-flow.

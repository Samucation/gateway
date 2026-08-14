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
| Compose do Kong único | ✅ porta **8050**, ao lado dos atuais |
| Subir o Kong único | ✅ `gateway-kong` na 8050, healthy |
| Comparar rota a rota | ✅ live-flow, sigma-financeiro e cafe-mobile-erp batem com o antigo |
| Frontend de operação | ⏳ vem do `sigma-payments-ops-ui` |
| Cortar os Kongs locais | ⏳ um por vez, no fim |

**Nada foi desligado.** O Kong novo nasce na 8050 para conviver com os antigos;
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
| 1 Kong servindo os 5 (**medido**) | **191 MB** |

Medido com o gateway no ar: `gateway-kong` 191,6 MiB contra `liveflow-kong`
2,16 GiB e `sigma-kong` 2,15 GiB — cada um servindo UM projeto.

Os 32 workers por Kong são o padrão (um por núcleo). Para 5 apps domésticos,
2 workers atendem de sobra.

## Provado até aqui

Com o Kong novo no ar, o mesmo `/` entrega apps diferentes conforme o host —
que é a prova de que a separação funciona:

| Host | Entrega |
|---|---|
| `urupix.com.br` | *Urupix — receba PIX na tela da sua live* |
| `sigma-financeiro.cursodetecnologia.dev.br` | *Sigma Financeiro* |
| `cafe-api.cursodetecnologia.dev.br` | *Plataforma de Atendimento* |
| host desconhecido | **404** — não cai em ninguém |

Conferido pelo `<title>`, não pelo código HTTP: três apps respondendo 200 no
mesmo caminho pareceriam idênticos olhando só o status.

## Ordem do corte (do menor risco para o maior)

1. ~~`central-ia`~~ ✅ **CORTADO em 14/08/2026** — `central-kong` removido
2. `cafe-mobile-erp` — API interna
3. `sigma-financeiro`
4. `live-flow` — **por último**: é o que tem live em produção

### ⚠️ O corte NÃO é só remover o container

O Kong **ignora a porta** ao casar `hosts:` — provado: `Host: urupix.com.br:9999`
casa igual. Então `localhost:8030` casaria como `localhost`, que nenhum projeto
pode reivindicar sozinho sem roubar os outros.

Por isso cada projeto sem domínio público ganha um **apelido no `hosts` do
Windows** (`central.interno`, `sigma-payments.interno` → 127.0.0.1), e os
consumidores passam a usar `http://<apelido>:8050`.

Procedimento por projeto:

1. apelido no `hosts` (exige admin) ou domínio público já existente;
2. **achar os consumidores** — `grep` pela porta antiga no workspace inteiro;
3. repontar cada consumidor e reiniciar quem precisar;
4. comparar rota a rota, **pelo conteúdo**, não pelo status;
5. `docker rm` do Kong local;
6. comentar o serviço no compose do projeto, senão ele volta no próximo `up`.

**Corte 1 — central-ia (feito):** o consumidor não era óbvio — era o
**live-flow**, em `CENTRAL_URL` (`src/lib/ai.ts`, geração de descrição por IA).
Remover o container sem repontar teria quebrado a IA do Urupix, longe da causa.

## Frontend

O console de operação virá do **`sigma-payments/sigma-payments-ops-ui`**
(Angular), que já tem páginas de services, routes, consumers, plugins,
upstreams e status, além de Prometheus, Keycloak e alertas. É a base mais
completa do workspace — bem mais que o painel de leitura do live-flow.

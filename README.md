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
| Conferir plugin a plugin | ✅ `npm run conferir` — 44 rotas, plugin efetivo idêntico |
| Frontend de operação | ⏳ vem do `sigma-payments-ops-ui` |
| Cortar os Kongs locais | 🔄 2 de 4 (`central-ia`, `cafe-mobile-erp`) |

## ⚠️ O erro que quase passou: navegar não prova plugin

A primeira versão do gerador **descartou 18 plugins**. Ela copiava só
`services:` e trocava o bloco `plugins:` de topo por três globais sem config,
assumindo que os cinco projetos configuravam `correlation-id`, `cors` e
`prometheus` do mesmo jeito. Não configuravam — o `cors` tem **cinco listas de
origens diferentes**, e `cors` sem `config.origins` libera **`*`**.

Foram embora, entre outros:

| Plugin | De quem | O que fazia |
|---|---|---|
| `ip-restriction` | cafe-mobile-erp | fechava a rota do operador |
| `rate-limiting` × 7 | cafe-mobile-erp | limite por rota |
| `request-size-limiting` | cafe-mobile-erp | teto de corpo |
| `X-Frame-Options: DENY` | central-ia | anti-enquadramento |
| `cors` com allowlist | os cinco | virou `*` |

**A comparação por HTTP passou limpa nos 13 caminhos** — mesmo status e mesmo
corpo, byte a byte. Faz sentido: rate-limit não dispara em 13 requisições,
`ip-restriction` não barra o localhost, e cabeçalho de resposta não muda o
corpo. Config de gateway errada não estoura, ela **atende sem a proteção**.

Por isso existe `scripts/conferir-plugins.mjs`: ele monta o conjunto EFETIVO de
plugins por rota dos dois lados (precedência rota > serviço > global) e compara
config a config. Contra o arquivo defeituoso ele acusa **85 divergências**;
contra o corrigido, passa. Rodar antes de qualquer corte.

**Nenhum plugin é global no gerado**, e isso é regra: num Kong por projeto
"global" quer dizer *este projeto*; num Kong único quer dizer *os cinco*.

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
2. ~~`cafe-mobile-erp`~~ ✅ **CORTADO em 14/08/2026** — `plataforma-kong` removido
3. `sigma-financeiro` — 2,20 GB
4. `live-flow` — **por último**: é o que tem live em produção. 2,23 GB

Os dois que faltam são **4,4 GB** — o ganho de verdade está neles. Os dois já
cortados eram os pequenos, de propósito: serviram para achar os erros de
procedimento (o consumidor escondido, os plugins descartados) num lugar onde
errar não derruba live.

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
4. `npm run conferir` — **plugin a plugin**, que é o que HTTP não vê;
5. comparar rota a rota, **pelo conteúdo**, não pelo status;
6. `docker rm` do Kong local;
7. comentar o serviço no compose do projeto, senão ele volta no próximo `up`.

**Corte 1 — central-ia (feito):** o consumidor não era óbvio — era o
**live-flow**, em `CENTRAL_URL` (`src/lib/ai.ts`, geração de descrição por IA).
Remover o container sem repontar teria quebrado a IA do Urupix, longe da causa.

**Corte 2 — cafe-mobile-erp (feito):** nenhum consumidor de aplicação
(`KONG_PORT` só alimentava o mapeamento do compose). Foi este corte que revelou
os 18 plugins descartados, porque o projeto declara **tudo** no `plugins:` de
topo — 16 entradas, zero aninhadas. Nos outros quatro a maioria já era
aninhada, e por isso o furo tinha passado despercebido.

Achado à parte, **preexistente e não introduzido pela migração**: o
`X-Frame-Options` da central-ia usa `replace:`, que só age se o upstream já
mandar o cabeçalho. O `/health` (motor `shelf`) manda, então vira `DENY`; a
página do **portal** não manda, e fica sem cabeçalho nenhum — enquadrável. O
Kong antigo se comportava igual. Corrigir pede `add:` ao lado do `replace:`,
mas é mudança de comportamento do projeto, fora do escopo do corte.

## Pendente de decisão do Samuel

**O túnel do `cafe-api` aponta para uma porta morta.** No `config.yml` do
cloudflared, `cafe-api.cursodetecnologia.dev.br` manda para `localhost:8080` —
onde não há nada escutando (o Kong do projeto estava na 8020). O domínio
responde **502 hoje**, e já respondia antes da migração.

Apontar para a `8050` conserta. Mas isso **volta a expor a API publicamente**,
e exposição pública é decisão do Samuel (R17) — por isso não foi feito junto
com o corte.

## Frontend

O console de operação virá do **`sigma-payments/sigma-payments-ops-ui`**
(Angular), que já tem páginas de services, routes, consumers, plugins,
upstreams e status, além de Prometheus, Keycloak e alertas. É a base mais
completa do workspace — bem mais que o painel de leitura do live-flow.

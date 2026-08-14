# gateway — um Kong para todo o ambiente

Hoje existem **cinco** Kongs, um por projeto, somando **4,75 GB**. Este projeto
substitui todos por um só, com a configuração de todos centralizada aqui.

O motivo não é organização: o Docker vinha **caindo por pressão de memória** e
derrubando o Urupix junto, no meio de live. Os dois maiores Kongs sobem 32
workers cada e rodam sem teto.

## ✅ Migração concluída — 14/08/2026

Os **cinco** Kongs locais foram removidos. `gateway-kong` atende todos os
projetos em **~190 MB**, contra os **4,75 GB** que os cinco somavam.

| | Antes | Agora |
|---|---:|---:|
| Containers de gateway | 5 | **1** |
| Memória | 4,75 GB | **190 MB** |

Ele ficou na **8050** e não assumiu a 8000: o túnel roteia por hostname, então
a porta virou detalhe interno — mudar só criaria outra janela de queda.

### Ganhos de segurança que vieram junto

| | |
|---|---|
| `KONG_REAL_IP_HEADER` | o `liveflow-kong` rodava **sem** — todos os visitantes do Urupix dividiam um balde de rate-limit |
| `/v1/platform`, `/painel`, `/api/cron` | fechados na internet (404), só por apelido interno |
| `/painel` do cafe-mobile-erp | **estava sem CSP**; agora os cabeçalhos são do serviço, não da rota |
| `cors` | seguiu com a allowlist de cada projeto (um global teria liberado `*`) |
| `KONG_HEADERS: off` | o gateway não anuncia mais qual software é |

## Estado da construção

| Etapa | |
|---|---|
| Mapear os 5 Kongs | ✅ [`docs/mapeamento.md`](docs/mapeamento.md) |
| Gerador da config unificada | ✅ `scripts/gerar-kong.mjs` |
| Config unificada (12 services, 44 rotas) | ✅ `kong/kong.yml` — `kong config parse` aprova |
| Compose do Kong único | ✅ porta **8050**, ao lado dos atuais |
| Subir o Kong único | ✅ `gateway-kong` na 8050, healthy |
| Comparar rota a rota | ✅ live-flow, sigma-financeiro e cafe-mobile-erp batem com o antigo |
| Conferir plugin a plugin | ✅ `npm run conferir` — 45 rotas, plugin efetivo idêntico |
| Conferir defesas de ambiente | ✅ `npm run ambiente` — 13 variáveis, contra o container RODANDO |
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
3. ~~`sigma-financeiro`~~ ✅ **CORTADO em 14/08/2026** — `sigma-kong` removido (2,3 GB)
4. ~~`live-flow`~~ ✅ **CORTADO em 14/08/2026** — `liveflow-kong` removido (2,37 GB)

**Os quatro cortados.** Cada corte pequeno serviu para achar um erro de
procedimento antes de chegar no que tem live: o consumidor escondido
(central-ia), os plugins descartados (cafe-mobile-erp) e o watchdog que
ressuscita o container (sigma-financeiro). O do live-flow, o mais arriscado,
não teve surpresa nenhuma — porque as três anteriores já tinham cobrado o
preço.

### Corte 4 — live-flow, o de produção

Feito com **zero live no ar**, conferido antes: nenhuma amostra em `LiveSample`
nos últimos 15 min (a última era de 8 h antes) e **zero conexões SSE** — que é
o que o overlay do OBS abre e mantém durante a transmissão.

| | |
|---|---|
| 18 rotas | mesmo status e mesmo corpo¹ |
| SSE do overlay | `read_timeout`/`write_timeout` de 1 h e `retries: 0` preservados |
| 6 cabeçalhos de segurança em `/`, `/login`, `/admin` | iguais |
| CORS | recusa origem invasora, aceita a allowlist |
| Kong antigo **pausado** | os três domínios seguiram em 200 |

¹ só o `time` do `/api/payments/health` diferiu — 44 ms, como tem que diferir.

### ⚠️ O watchdog desfaz a migração sozinho

O `sigma-financeiro/deploy/windows/watchdog.ps1` vigiava `127.0.0.1:8010` e,
ao ver a porta morta, rodava `docker rm -f sigma-kong` seguido de
`docker compose up -d kong`. Ele **recriaria o Kong removido em minutos**, de
minuto em minuto, e nada no resultado denunciaria isso — o container voltaria
com o mesmo nome e a mesma config.

Todo projeto com watchdog precisa ser apontado para o gateway **antes** do
`docker rm`. E o conserto ficou condicionado a `-not $publicoOk`: o gateway é
**compartilhado**, e recriá-lo por uma falha local derruba os cinco projetos
por um problema de um.

O `live-flow` tem watchdog igual — conferir antes do corte 4.

### Como o corte 3 foi provado

| | |
|---|---|
| 10 rotas, status e corpo | idênticos byte a byte¹ |
| 6 cabeçalhos de segurança em `/`, `/admin`, `/portal` | iguais nos dois |
| `npm run seguranca` | plugin efetivo + ambiente ✅ |
| Kong antigo **pausado** | domínio seguiu em 200 |

¹ depois de normalizar o nonce da CSP, que muda a cada requisição por desenho e
aparece em **três** formas: no header, no atributo HTML e escapado dentro do
payload RSC. Normalizar só as duas primeiras ainda acusava diferença — e
parar aí teria deixado a dúvida de pé.

Pausar o Kong antigo antes de removê-lo é o teste que vale: responder 200 com
ele no ar não prova nada sobre quem está atendendo.

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

## 🔒 O IP do cliente — o que sustenta metade das defesas

**Sem `KONG_REAL_IP_HEADER`, o Kong acha que todo mundo é o `cloudflared`.**
Quem abre a conexão é o túnel, da própria máquina, então o IP visto é privado
(`172.23.0.1`). Duas consequências, as duas silenciosas:

1. **`ip-restriction` vira decoração.** A rota do operador do cafe-mobile-erp
   só libera faixas privadas — e o túnel chega justamente como faixa privada.
   Medido: `/v1/platform` devolvia **401** (chegou na aplicação) onde devia
   devolver 404.
2. **`rate-limiting` com `limit_by: ip` põe a internet num balde só.** Um
   abusador leva todos os usuários a 429 junto, e o log culpa o túnel.

Os quatro projetos já configuravam isso; **o gateway não**, e eu só descobri
comparando as variáveis de ambiente de cada compose com as minhas. Agora ele
usa `CF-Connecting-IP` — e não `X-Forwarded-For`, porque a Cloudflare
**sobrescreve** aquele na borda e o cliente não consegue forjar; o XFF é lista
e aceita item novo na frente.

Provado: requisição vinda da internet aparece no log com o IPv6 público real;
a local, com `172.24.0.1`.

> ⚠️ `liveflow-kong` está rodando **sem** essas variáveis, apesar de o compose
> dele as declarar — foi subido por outro caminho. Ou seja, o Urupix hoje
> limita taxa pelo IP do túnel. Cortar o Kong dele **conserta isso de brinde**.

## Rotas internas — proteção que não depende de header

Rotas de operação (`rotasInternas` no gerador) recebem **só o apelido interno**,
nunca o domínio público. `/v1/platform` e `/painel` do cafe-mobile-erp são as
primeiras: a API enxerga todos os clientes, e o painel é a tela que a consome.

**Só isso não bastou, e a primeira tentativa deixou o sistema MENOS seguro.**
O projeto tem uma rota `/`, que casa por prefixo: tirar `/painel` do host
público não fechou o caminho — fez o pedido cair no `/` e ser servido pela rota
do site, **sem o `ip-restriction`**. Medido: `/v1/platform` da internet passou
de 404 para 401.

Por isso cada rota interna ganha uma **gêmea de bloqueio** no host público, com
`request-termination` devolvendo 404. E ela precisa declarar `methods`: sem
isso perdia para a rota do site no GET e só bloqueava no POST — um bloqueio que
funciona no método que ninguém usa.

Hoje, da internet, os seis métodos devolvem 404 nas duas rotas; pelo
`cafe.interno` as duas seguem funcionando.

## `cafe-api` agora está no ar (era 502)

O túnel apontava para `localhost:8080`, morta desde que o Kong do projeto foi
para a 8020 — o domínio devolvia **502 antes da migração**. Agora entra pelo
gateway.

⚠️ Editar o `config.yml` do cloudflared **pelo PowerShell 5.1 quebrou o
túnel**: `Get-Content -Raw` lê UTF-8 como ANSI e a regravação corrompe os
bytes; o serviço sobe e morre em seguida, derrubando o Urupix junto. Editar
preservando o encoding e **validar antes de reiniciar**:

```bash
cloudflared --config <caminho> tunnel ingress validate   # a flag vem ANTES do subcomando
```

## Frontend

O console de operação virá do **`sigma-payments/sigma-payments-ops-ui`**
(Angular), que já tem páginas de services, routes, consumers, plugins,
upstreams e status, além de Prometheus, Keycloak e alertas. É a base mais
completa do workspace — bem mais que o painel de leitura do live-flow.

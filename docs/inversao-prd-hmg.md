# A inversão: a remota vira PRD, esta máquina vira HMG

Decidido em 19/08/2026. Quando a migração terminar:

| | Máquina | Hostnames |
|---|---|---|
| **PRD** | a remota (`serverhomol`) | os de hoje — `urupix.com.br`, `sigma-midia.cursodetecnologia.dev.br`… |
| **HMG** | esta estação | os mesmos com sufixo — `sigma-midia-hmg`, `urupix-hmg`… |

**A direção está certa, e não é indiferente.** PRD ficando com os hostnames
atuais significa que **nada registrado em terceiro precisa ser mexido para
produção continuar funcionando**: redirect de OAuth, webhook de pagamento,
verificação de domínio, tudo continua apontando para o mesmo nome. O risco fica
todo do lado de HMG — que é o lado onde ele é barato.

O caminho inverso (HMG com os nomes atuais) obrigaria a reapontar toda
integração externa de produção num único dia. Não fazer isso.

---

## O que HMG perde, e o que custa recuperar

Esta é a lista real, levantada do código em 19/08/2026 — não é hipótese.

### 1. Google OAuth — recupera BARATO ✅

O Google aceita **várias** URIs de redirecionamento por cliente OAuth. Basta
acrescentar a de HMG na mesma aplicação:

```
https://urupix-hmg.cursodetecnologia.dev.br/api/auth/callback/google
```

A verificação do app (aprovada em 19/08/2026) é **por escopo**, não por URI —
acrescentar uma URI não reabre a análise. O subdomínio precisa estar sob um
domínio já verificado, e está.

### 2. Mercado Pago — NÃO recupera sem uma segunda aplicação ⚠️

**Este é o problema de verdade.** No painel do MP a URL de redirecionamento é
**uma só por aplicação** (campo singular, em *Configuração avançada*). Não há
lista.

O código monta a URI a partir da origem da requisição:

```ts
const redirectUri = `${origin}/api/mp/oauth/callback`;   // src/app/api/mp/oauth/start/route.ts
```

Ou seja: servido em `urupix-hmg…`, o Urupix vai pedir ao MP um redirect que o MP
**não conhece**, e o MP recusa **toda** conexão com:

> Desculpe, não foi possível conectar o aplicativo à sua conta

⚠️ **Isso já aconteceu, exatamente assim, em julho de 2026** — na época só a URL
do domínio antigo estava cadastrada. O sintoma não menciona redirect nenhum.

**A saída certa é uma SEGUNDA aplicação no MP, só para HMG**, com credencial de
teste. Isso conversa com a pendência que já existe (a credencial sandbox do
Mercado Pago). A alternativa — ficar trocando a URI de uma aplicação só — é pior
que não ter HMG: cada troca derruba produção.

> E lembrar: o MP **proíbe o dono do app conectar a própria conta**. Testar em
> HMG exige conta MP diferente da que criou a aplicação, ou conta de teste.

### 3. Webhooks de pagamento — NÃO apontar para HMG 🚫

`https://urupix.com.br/api/webhooks/mercadopago` e equivalentes são
configurados **na conta do provedor**. Não é "quebra em HMG": é que apontá-los
para HMG faria **evento de dinheiro real chegar no ambiente de teste**.

A regra é a que já vale na casa: **HMG só fala com sandbox.** Webhook de
produção continua indo para PRD, e HMG registra o webhook da conta sandbox.

### 4. As URLs assinadas do sigma-midia — os segredos precisam DIVERGIR ⚠️

Na migração de 19/08/2026 eu **preservei** a chave e o sal do imgproxy e a
credencial de serviço do S3. Estava certo: era a mesma instalação mudando de
casa, e trocar teria quebrado toda URL já publicada.

**Depois da inversão isso deixa de estar certo.** Passam a ser dois ambientes, e
com a mesma chave:

- uma URL assinada em **HMG** é válida em **PRD**;
- quem tiver acesso ao HMG (que é o ambiente frouxo, por definição) pode assinar
  caminhos que produção aceita.

Então, no dia do corte: **HMG gera chave e sal novos**. As URLs de HMG param de
valer em PRD, que é o comportamento desejado.

O mesmo vale para `MIDIA_S3_ENDPOINT_PUBLICO` — em HMG ele passa a ser
`https://sigma-midia-hmg-arquivos…`, e é isso que separa os dois acervos.

### 5. Keycloak — só configuração ✅

O `issuer` é um endereço nosso, não de terceiro. Basta HMG apontar para o
Keycloak de HMG. Já está parametrizado (`KC_HOSTNAME`).

⚠️ Mas vale a lembrança: **`issuer` errado recusa todo token**, com uma mensagem
que fala de emissor inválido e não de configuração.

---

## O inventário de hostnames

12 hostnames hoje no Kong — 8 públicos e 4 internos (`.interno`):

```
cafe-api.cursodetecnologia.dev.br      urupix.com.br
opuschat.cursodetecnologia.dev.br      www.urupix.com.br
sigma-financeiro.cursodetecnologia…    urupix.cursodetecnologia.dev.br
sigma-midia.cursodetecnologia.dev.br   central-ia*.cursodetecnologia.dev.br
```

Os `.interno` (`cafe.interno`, `central.interno`, `sigma.interno`,
`sigma-payments.interno`) **não precisam de sufixo**: já são locais, e cada
máquina resolve o seu. Duplicá-los seria só ruído.

---

## A ordem de trabalho

1. **Terminar a migração** — todo projeto rodando na remota, ainda servido pelo
   Kong daqui.
2. **Cortar Kong e túnel** para a remota (Fase 4 do plano). PRD passa a ser lá,
   com os nomes de hoje. **Nada externo é mexido.**
3. **Só então** montar HMG aqui, com os sufixos. É aqui que entram os itens 1, 2
   e 4 acima.

⚠️ **O passo 3 é o único que precisa de cadastro em terceiro**, e ele vem por
último de propósito: se a inversão for feita antes do corte, produção fica sem
os registros e o estrago é imediato.

---

## O que fazer ANTES do passo 3

- [ ] Criar a **segunda aplicação no Mercado Pago** para HMG (credencial de teste)
- [ ] Acrescentar a URI de HMG no cliente OAuth do Google
- [ ] Gerar **chave e sal novos** do imgproxy para o sigma-midia de HMG
- [ ] Conferir que **nenhum webhook de produção** aponta para HMG
- [ ] Registrar os hostnames `-hmg` no DNS e no túnel

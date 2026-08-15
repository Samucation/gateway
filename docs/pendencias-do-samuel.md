# Pendências que dependem do Samuel

Coisas prontas em código, esperando credencial ou decisão. Anotado em 15/08/2026.

## 1. Chave para o aviso de ataque chegar no celular

**Estado:** o vigia detecta abuso, grava em `console/dados/incidentes.jsonl` e
**diz no log que ninguém foi avisado**. Falta só a credencial.

O aviso sai pela plataforma de mensageria da casa (`cafe-mobile-erp`), não por
integração própria — o gateway é um tenant como qualquer outro.

```bash
GATEWAY_MSG_CHAVE=<api key de um tenant "gateway" na plataforma>
GATEWAY_MSG_PARA=<chat id do Telegram, ou telefone com DDI>
GATEWAY_MSG_CANAL=telegram
```

**O que fazer:** criar o tenant e a API key na plataforma; criar um bot no
`@BotFather` (recomendo um próprio, não o do Café — se aquele token for trocado
por causa do produto, os alertas param sem aviso); mandar `/start` ao bot e
pegar o `chat id` em `api.telegram.org/bot<TOKEN>/getUpdates`.

⚠️ O `chat id` **não** é o nome de usuário. O Telegram só deixa um bot escrever
para quem já falou com ele.

## 2. Chaves da API de relatórios, por projeto

**Estado:** a API existe e funciona. O Urupix já consome com uma chave de teste
(`chave-urupix`), que **precisa virar uma de verdade**.

```bash
# no gateway
GATEWAY_API_CHAVES=<chave-forte>:liveflow,<outra>:sigmafin,<outra>:plataforma

# em cada projeto consumidor (exemplo: live-flow/.env)
GATEWAY_API_CHAVE=<a mesma chave-forte do liveflow>
```

Uma chave por aplicação. O `app` vem da chave, nunca do pedido.

## 3. `/admin` do sigma-financeiro continua público

**Decisão sua, não mexi.** Ele responde pelo domínio público, protegido por
allowlist + 2FA na aplicação. Fechá-lo no host interno (como `/painel` e
`/v1/platform` do cafe) quebraria seu acesso remoto.

## Ideias combinadas, ainda não começadas

- **Canal web na plataforma de mensageria** — hoje só Telegram e WhatsApp. É o
  que falta para o "fale conosco" com robô na landing do Urupix.
- **Widget de chat na landing**, consumindo esse canal.
- **Renomear `cafe-mobile-erp`** para algo ligado a chat/mensageria. O nome
  descreve o primeiro cliente, não o produto — e agora o gateway depende dele,
  o que torna a confusão mais cara. Mexe em rede Docker, container, host do
  gateway (`cafe-api...`) e túnel: fazer numa janela combinada.

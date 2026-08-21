# O sigma-financeiro na VM é igual ao da estação — a prova

Feito em 21/08/2026, no corte. Guardado porque "migrei e parece funcionar" não
é prova de nada quando há dinheiro no meio: o serviço sobe e responde 200 em
vários cenários em que ele NÃO cobraria.

Cada linha abaixo foi executada nos DOIS lados, com a MESMA entrada.

## 1. O ambiente que cada instância declara

    GET /api/ambiente

    estação: {"ambiente":"live","build":"lvubz-...","migracao":"20260814175742_reserva_de_referencia"}
    VM     : {"ambiente":"live","build":"PoPwRFV...","migracao":"20260814175742_reserva_de_referencia"}

Mesma migração de banco, mesmo ambiente. O `build` difere de propósito — são
imagens construídas em momentos diferentes.

⚠️ `live` é a ÚNICA palavra que liga cobrança real. O código faz
`SIGMA_AMBIENTE === "live" ? "live" : "sandbox"`; qualquer outra cai em sandbox
SEM RECLAMAR. O comentário do `k8s/base` dizia `producao` — está errado, e o
erro seria silencioso.

## 2. O conteúdo dos bancos

    adquirentes | aplicações | credenciais | cobranças | recebedores
    estação:  0 | 1 | 1 | 24 | 2
    VM:       0 | 1 | 1 | 24 | 2

Os dois carimbados `live` na tabela `Settings`.

⚠️ `AppDoAdquirente = 0` NÃO é falha da migração — é o estado real da produção.
Sem adquirente cadastrado, uma cobrança não completa em NENHUM dos dois.

## 3. Chamada autenticada, com a credencial que o Urupix usa

    GET /api/v1/charges  (Authorization: Basic client_id:client_secret)

    estação: 200
    VM     : 200
    corpo  : IDÊNTICO, byte a byte

⚠️ Esta é a prova que importa mais. A credencial fica CIFRADA no banco com o
`TOKEN_ENCRYPTION_KEY`. O cluster tinha chave própria (correto enquanto era
homologação); ao trazer o banco de produção ela precisou virar a de lá. Com a
chave errada, a decifragem falha e o código trata como "não configurado": o
serviço sobe, responde 200 na home, e as credenciais somem sem uma linha de
erro. Impressão SHA-256 conferida: `520d216206de054f` dos dois lados.

## 4. Webhooks

    POST /api/webhooks/MERCADO_PAGO   estação: 401   VM: 401
    POST /api/webhooks/WOOVI          estação: 401   VM: 401
    POST /api/webhooks/ASAAS          estação: 401   VM: 401

401 é a resposta CERTA: a rota está viva e exigindo assinatura.

⚠️ Os nomes são MAIÚSCULOS (`MERCADO_PAGO`, não `mercadopago`). Com o nome
minúsculo os dois devolvem 404 — e 404 aqui parece "rota não migrou", quando é
só o nome errado. Foi o que me enganou primeiro.

Saída (o sigma chamando de volta): o destino cadastrado é
`https://urupix.com.br/api/webhooks/sigma`, que hoje resolve para a VM, e ele
responde 401 sem assinatura — vivo e protegido.

## O que continua faltando para cobrar de verdade

Não é da migração: já faltava aqui.

- **Nenhum adquirente cadastrado** (`AppDoAdquirente` vazio). Enquanto isso, o
  serviço está `live` mas sem provedor para executar a cobrança.
- Credencial de sandbox do Mercado Pago, para dar para testar sem dinheiro real.

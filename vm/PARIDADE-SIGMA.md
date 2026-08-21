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

⚠️ `AppDoAdquirente = 0` NÃO significa "sem Mercado Pago" — eu li isso errado
primeiro e disse ao dono que faltava cadastrar adquirente. Estava errado.

A credencial do adquirente mora em **`Receiver.credentialsEnc`**, cifrada, POR
RECEBEDOR. `AppDoAdquirente` é outra coisa (registro de aplicação OAuth).

    label                                | provider     | própria | tem cred | ativo
    Plataforma Urupix (conta da casa)    | MERCADO_PAGO |    t    |     t    |   t
    Samuel "Ed Sheeran dos Games"        | MERCADO_PAGO |    f    |     t    |   t

Idênticos nos dois lados.

## 2b. As credenciais do Mercado Pago decifram na VM — prova sem cobrar ninguém

A decifragem só acontece ao CRIAR COBRANÇA (`aplicacao/criar-cobranca.ts`) e ao
confirmar pagamento — os dois caminhos movem dinheiro de verdade. Não há
endpoint de "testar credencial".

Então a prova é por determinismo, e não por experimento: cifra simétrica com a
MESMA chave sobre o MESMO texto cifrado devolve o MESMO texto claro.

    chave (SHA-256, 16 primeiros):
      estação: 520d216206de054f
      VM     : 520d216206de054f

    texto cifrado (MD5 de credentialsEnc):
      Plataforma Urupix (conta da casa):  d1d57554090a926303558e912cfd40e9  (os dois)
      Samuel "Ed Sheeran dos Games":      12417a3de46d88190d4ea1dc3beb004e  (os dois)

E o token que o Urupix usa direto com o Mercado Pago, fora do sigma, também
confere — MP_ACCESS_TOKEN, MP_CLIENT_ID, MP_CLIENT_SECRET e MP_WEBHOOK_SECRET,
todos com a mesma impressão dos dois lados.

⚠️ O que NÃO foi feito: criar uma cobrança de verdade. Em `live` isso é dinheiro
real, e a regra do dono é testar só em sandbox. A prova acima dá certeza sem
precisar disso.

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

- Credencial de SANDBOX do Mercado Pago. Sem ela não há como exercitar o fluxo
  de cobrança de ponta a ponta sem dinheiro real — e é a única coisa que separa
  "provado por determinismo" de "provado por uma doação que entrou".

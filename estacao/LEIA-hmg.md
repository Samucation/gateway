# A estação virou HOMOLOGAÇÃO — como funciona

Feito em 21/08/2026, depois de a produção mudar para a VM.

## O desenho

    você faz `git push`
        ↓
    Jenkins (roda NA VM) — testa, Sonar, portão de qualidade
        ↓
    imagem publicada no registro da VM (localhost:32000 de lá)
        ↓
    ┌──────────────────────────┬─────────────────────────────┐
    │ ESTAÇÃO (aqui)           │ VM serverhomol              │
    │ cluster k3d `hmg`        │ MicroK8s = PRODUÇÃO         │
    │ *-hmg.cursodetecnologia  │ urupix.com.br e cia.        │
    │ sobe SOZINHO             │ só com o botão "Promover"   │
    └──────────────────────────┴─────────────────────────────┘

⚠️ O registro de imagens é **um só**, o da VM. O cluster daqui o acessa por
espelho (`estacao/k3d-hmg.yaml`): `localhost:32000` nos manifestos aponta para
lá. Assim o que você testa aqui é **exatamente o mesmo binário** que sobe em
produção — não uma recompilação parecida.

## Por que k3d, e não MicroK8s

Esta estação é Windows. MicroK8s exigiria mais uma VM Linux — uma camada inteira
a mais para manter.

O k3d roda k3s em contêiner, e o **k3s já traz o Traefik**. Como os manifestos
declaram `ingressClassName: traefik` (a VM usa o addon `ingress` do MicroK8s,
que é Traefik), os **mesmos YAML valem nos dois lados**, sem adaptação. É isso
que faz homologação valer alguma coisa.

O Kubernetes do Docker Desktop sobe sem controlador de ingress; instalar o
Traefik à mão seria uma segunda instalação, livre para divergir da de lá.

## O que é DIFERENTE aqui, de propósito

⚠️ **Nenhuma credencial de pagamento.** `estacao/segredos-hmg.ps1` cria os
Secrets com as chaves de Mercado Pago, adquirente e e-mail **vazias**. Com elas
preenchidas, um teste de doação cobraria uma pessoa de verdade — e o teste teria
passado, porque cobrar funcionou.

⚠️ **Chaves de cifra próprias e geradas.** `TOKEN_ENCRYPTION_KEY` e
`AUTH_SECRET` são diferentes das de produção. Iguais, um token cifrado aqui
valeria lá, e uma sessão daqui abriria a conta de lá.

⚠️ **Nada de envio para fora.** Resend, FCM e VAPID vazios: a base de teste veio
de um dump da produção e tem **endereços de e-mail reais**. Com a chave
preenchida, homologação mandaria e-mail para clientes.

## Túnel separado

O de homologação é `hmg-estacao` (`d2b14ffb`), **criado novo**. O de produção
(`47a05dc3`) mudou de máquina e roda na VM.

⚠️ Reaproveitar o mesmo ID nos dois lugares faria a Cloudflare DIVIDIR o tráfego
entre eles — metade das requisições reais cairia no ambiente de teste. Não é
teoria: aconteceu durante o corte, quando um watchdog ressuscitou o túnel de
produção aqui enquanto ele já rodava na VM.

## Os nomes levam `-hmg`

`urupix-hmg.cursodetecnologia.dev.br`, e assim por diante.

Não é enfeite: é a proteção mais barata contra o erro mais caro — abrir a aba
errada e mexer em produção achando que é teste.

## Para religar o deploy automático em homologação

O estágio de homologação da esteira está desligado por uma guarda (`HMG_CONTEXTO`
vazio), porque enquanto ele apontava para a VM ele DESFAZIA produção a cada
build. Para religar, definir `HMG_CONTEXTO` no Jenkins apontando para este
cluster.

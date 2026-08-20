# O Kong da máquina remota — preparação do corte

Este diretório monta o gateway na VM **sem tocar em nada público**. Enquanto o
túnel continuar rodando nesta estação, o que está aqui não recebe uma
requisição sequer de fora.

---

## O caminho, antes e depois

```
HOJE     internet → túnel (estação) → :8050 Kong (estação) → aplicação (estação)

DEPOIS   internet → túnel (VM)      → :8050 Kong (VM)      → Traefik → Pod
```

O que muda é **para onde o túnel aponta**. Nada é desligado nem apagado: a
estação continua íntegra, e é para ela que se volta se algo falhar.

---

## ⚠️ O Kong roda DENTRO do cluster, não em Docker

Era para ser Docker, como na estação. Medido em 20/08/2026:

```
07:17:17  docker compose up  ->  cria a rede vm_default
07:17:22  systemd: Stopping snap.microk8s.daemon-kubelite   <- 4 segundos
```

Todos os Pods reiniciaram. O MicroK8s vigia mudanças de interface — precisa
disso para reemitir certificado quando o IP muda — e uma ponte nova do Docker
dispara a detecção.

Ou seja: **cada `docker compose up` na máquina derruba o cluster**. Para um
gateway de produção é inaceitável — reiniciar o gateway reiniciaria as
aplicações atrás dele.

Dentro do cluster o problema some, e de quebra o Kong fala **direto com os
Services**: um salto a menos que passar pelo Traefik, e sem depender de
`preserve_host`.

> `docker build` **não** cria rede, então os builds do Jenkins são seguros.

## Por que o Kong continua existindo

Daria para o túnel falar direto com o Traefik do cluster. Não vale:

- o Kong faz o que o Traefik aqui não está configurado para fazer — limite de
  requisição, correlação, CORS, lista de IP no admin, teto de corpo;
- a regra da casa é **um gateway só**, e ele é gerado por
  `scripts/gerar-kong.mjs` a partir do `kong.yml` de cada projeto. Esse gerador
  é o que impede a configuração de divergir, e custou caro para ficar certo.

O Traefik não some: ele continua sendo a entrada **de dentro** do cluster. São
camadas, não concorrentes.

---

## ⚠️ `preserve_host` é o que faz isto funcionar

O Kong, por padrão, reescreve o cabeçalho `Host` para o endereço do destino. Se
ele fizesse isso aqui, o Traefik receberia `Host: host.docker.internal` e não
saberia para qual Ingress mandar — **todas as requisições cairiam no mesmo
lugar, ou em nenhum**.

Com `preserve_host: true` o `Host` original atravessa, e é por ele que o Traefik
decide. É o único ajuste estrutural em relação ao Kong da estação.

---

## O que ainda falta, e por que o corte NÃO pode ser hoje

⚠️ **Os bancos da VM estão vazios.** Medido em 20/08/2026:

| Projeto | Dado na VM |
|---|---|
| sigma-midia | 163 ativos — **migrado** |
| urupix | 0 usuários, 0 doações |
| sigma-financeiro | 0 tabelas |
| opuschat / plataforma | esquema criado, sem dado |

Cortar assim mandaria `urupix.com.br` — produto no ar, com doação PIX de gente
de verdade — para um banco vazio. E uma doação que chegasse no intervalo seria
gravada lá e ficaria **órfã** na volta, porque a volta reativa o banco antigo.

A migração de dados vem antes, e tem que ser **fresca**: copiar agora produz
cópia velha, que precisaria ser refeita no dia. Por isso ela é um script
testado, para rodar na hora do corte.

---

## A ordem do corte, quando chegar o dia

⚠️ **O watchdog é o passo 1, não o 2.** Ele roda a cada minuto e faz
`Restart-Service NerdQuizTunnel -Force`. Parar o túnel sem desligá-lo antes o
traz de volta em 60 segundos — e aí **os dois túneis rodam juntos**.

Isso importa porque um túnel Cloudflare aceita várias instâncias e **distribui o
tráfego entre elas**. Metade das requisições iria para cada máquina, e nada daria
erro: cada uma funcionaria, só que em ambientes diferentes.

```powershell
# 1. desligar o watchdog (ANTES de tudo)
Disable-ScheduledTask -TaskName NerdQuizTunnelWatchdog

# 2. parar o túnel daqui
Stop-Service NerdQuizTunnel

# 3. subir na VM
ssh usuario@<vm> 'sudo systemctl start cloudflared'

# 4. conferir os 20 hostnames públicos, um a um

# ---- SE FALHAR: volta em menos de um minuto ----
ssh usuario@<vm> 'sudo systemctl stop cloudflared'
Start-Service NerdQuizTunnel
Enable-ScheduledTask -TaskName NerdQuizTunnelWatchdog
```

**Fazer de madrugada**, quando o Urupix tem menos audiência ao vivo.

---

## E o HMG, depois

⚠️ Este túnel **não pode ser reconfigurado** para servir os `-hmg`. Um túnel é
um ID; o mesmo ID em duas máquinas vira réplica, e o Cloudflare divide o
tráfego. Com o config daqui trocado para `-hmg`, metade das requisições de
**produção** viria parar nesta máquina e cairia no `404` da regra final.

O HMG precisa de um **túnel novo**: `cloudflared tunnel create urupix-hmg` (ou
nome equivalente), ID próprio, credencial própria e registros de DNS próprios
para cada `-hmg`.

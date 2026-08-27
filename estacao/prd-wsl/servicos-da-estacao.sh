#!/usr/bin/env bash
# ===========================================================================
# Dá NOME de cluster ao que roda fora dele, na máquina Windows.
#
#     bash servicos-da-estacao.sh
#
# ---------------------------------------------------------------------------
# POR QUE ISTO EXISTE
# ---------------------------------------------------------------------------
# Três coisas ficaram fora do Kubernetes de propósito: o sandbox do
# sigma-financeiro (roda nativo no Windows) e a pilha de voz/GPU (Chatterbox,
# Kokoro, Whisper — em Docker, porque o cluster ainda não recebeu manifesto
# para GPU).
#
# As aplicações herdaram do compose endereços como `host.docker.internal:8004`
# e `localhost:3201`. Dentro do k3s:
#
#     host.docker.internal  -> não existe (é invenção do Docker Desktop)
#     localhost             -> é o PRÓPRIO Pod, não a máquina
#
# Ou seja: configuração que continua PARECENDO certa no arquivo e aponta para
# lugar nenhum. Nada falha na partida — falha quando alguém tenta usar a voz,
# ou pagar.
#
# ⚠️ E a correção óbvia (escrever o IP da estação em cada Secret) espalha o
# mesmo endereço por sete lugares. Quando ele mudar — e vai mudar, o DHCP desta
# rede ainda não tem reserva — são sete lugares para lembrar.
#
# Aqui o endereço mora em UM lugar: um Service sem seletor, com Endpoints
# apontando para a estação. As aplicações falam com `chatterbox.estacao`, e o
# dia da mudança de IP é uma linha só.
# ===========================================================================
set -uo pipefail

# O IP da estação na rede. O gateway da distro (172.29.x.1) também alcança, mas
# ele MUDA a cada reinício do WSL — e o sintoma seria a voz parar de funcionar
# depois de um reboot, sem ninguém ter mexido em nada.
IP=${IP_DA_ESTACAO:-192.168.15.9}

echo "== conferindo que a estacao responde em $IP =="
vivos=0
# O `quatrosaas` (4saas) esteve aqui por um dia — 26/08/2026 — enquanto não
# cabia no cluster. Em 27/08 o teto de memória do WSL subiu de 32 para 40 GB,
# ele virou Deployment no namespace `quatrosaas`, e a ponte saiu.
#
# Fica o registro porque a promessa foi cumprida: "isto é ponte, não destino".
# Ponte que ninguém remove vira caminho oficial, e no dia da mudança de IP da
# estação alguém descobre que metade do tráfego passava por aqui.
#
# Os quatro que sobraram são de outra natureza: motores que SEMPRE viveram na
# estação (GPU, voz) e não têm por que entrar no cluster.
declare -A PORTAS=( [sandbox-sigma]=3201 [chatterbox]=8004 [kokoro]=8880 [whisper]=8040 )
for nome in "${!PORTAS[@]}"; do
  p=${PORTAS[$nome]}
  cod=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$IP:$p/" 2>/dev/null)
  # 404 conta como VIVO: o serviço respondeu, só não tem rota em `/`.
  if [ "$cod" != "000" ]; then
    printf '  %-16s :%-5s %s  no ar\n' "$nome" "$p" "$cod"; vivos=$((vivos+1))
  else
    printf '  %-16s :%-5s %s  ⚠️ nao responde -- o Service fica criado, e vai dar 502 ate subir\n' "$nome" "$p" "$cod"
  fi
done
echo "  $vivos de ${#PORTAS[@]} respondendo"

kubectl create namespace estacao --dry-run=client -o yaml | kubectl apply -f - >/dev/null

for nome in "${!PORTAS[@]}"; do
  p=${PORTAS[$nome]}
  # Service SEM seletor + Endpoints escrito à mão: é assim que se aponta um
  # nome de cluster para algo que não é Pod.
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: $nome
  namespace: estacao
  labels: { app.kubernetes.io/part-of: estacao }
spec:
  ports:
    - name: http
      port: $p
      targetPort: $p
---
apiVersion: v1
kind: Endpoints
metadata:
  name: $nome
  namespace: estacao
subsets:
  - addresses: [ { ip: $IP } ]
    ports: [ { name: http, port: $p } ]
YAML
  echo "  $nome.estacao.svc.cluster.local:$p -> $IP:$p"
done

echo
echo "== conferindo pelo nome, de dentro do cluster =="
for nome in "${!PORTAS[@]}"; do
  p=${PORTAS[$nome]}
  cod=$(kubectl run confere-$RANDOM --rm -i --restart=Never --image=curlimages/curl:8.10.1 --quiet -- \
        -s -o /dev/null -w '%{http_code}' --max-time 6 "http://$nome.estacao.svc.cluster.local:$p/" 2>/dev/null | tr -d '\r')
  printf '  %-16s %s\n' "$nome" "${cod:-000}"
done

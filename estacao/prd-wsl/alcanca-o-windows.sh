#!/usr/bin/env bash
# Um Pod do k3s alcança os serviços que rodam NA MÁQUINA Windows?
#
# Sobraram três coisas fora do cluster de propósito: o sandbox do
# sigma-financeiro (3201), a pilha de voz/GPU (Chatterbox 8004, Kokoro 8880,
# Whisper 8040) e o NerdQuiz. As configurações herdadas do compose apontam para
# `host.docker.internal` ou `localhost`, que dentro do k3s não levam a lugar
# nenhum. Este script descobre o endereço que LEVA.
set -uo pipefail

GW=$(ip route | awk '/^default/ {print $3; exit}')
LAN=192.168.15.9

echo "  gateway da distro: $GW"
echo "  IP da estacao na rede: $LAN"
echo

testar() { # <endereco> <porta> <oq>
  local cod
  cod=$(kubectl run alcance-$RANDOM --rm -i --restart=Never --image=curlimages/curl:8.10.1 --quiet -- \
        -s -o /dev/null -w '%{http_code}' --max-time 6 "http://$1:$2/" 2>/dev/null | tr -d '\r')
  printf '  %-18s :%-6s %-6s %s\n' "$1" "$2" "${cod:-000}" "$3"
}

echo "== de dentro de um Pod, pelo gateway da distro =="
for p in 3201 8004 8880 8040; do testar "$GW" "$p" ""; done

echo
echo "== de dentro de um Pod, pelo IP da estacao na rede =="
testar "$LAN" 3201 "sandbox do sigma-financeiro"
testar "$LAN" 8004 "Chatterbox (voz)"
testar "$LAN" 8880 "Kokoro (voz)"
testar "$LAN" 8040 "Whisper (transcricao)"

#!/usr/bin/env bash
# O canal que leva o alerta até o OBS está aberto?
#
# O overlay recebe os eventos por SSE em `/api/overlay/stream`. Se esse canal
# estiver fechado, NENHUM alerta chega — nem com áudio nem sem — e o que o
# streamer vê é "não aconteceu nada".
#
# ⚠️ E se o canal estiver aberto mas o evento chegar SEM `audioUrl`, o overlay
# cai na voz do navegador. São duas falhas diferentes com o mesmo sintoma na
# live, e esta é a única forma de separá-las sem estar na frente do OBS.
set -uo pipefail
BASE=${BASE_URUPIX:-http://127.0.0.1:80}
HOST=${HOST_URUPIX:-urupix.com.br}

echo "== a rota do canal responde? =="
# ⚠️ SSE não fecha sozinho: o `--max-time` é o que encerra. Sem ele, isto pendura.
cod=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
      -H "Host: $HOST" -H 'Accept: text/event-stream' \
      "$BASE/api/overlay/stream" 2>/dev/null)
echo "  /api/overlay/stream -> ${cod:-000} (000 aqui costuma ser o tempo limite do teste, e não falha)"

echo
echo "== o Kong tem rota propria para o canal? =="
# Ela existe porque SSE é conexão LONGA: sem `read_timeout` alto, o gateway
# corta a conexão no meio e o overlay some da live sem erro nenhum.
kubectl get cm kong-config -n gateway -o jsonpath='{.data.kong\.yml}' 2>/dev/null \
  | grep -A 3 'liveflow-overlay-streams' | head -6 | sed 's/^/  /'

echo
echo "== o cache de voz ja tem arquivo? =="
pod=$(kubectl get pods -n urupix -l app=urupix-app --no-headers 2>/dev/null | grep ' Running ' | tail -1 | awk '{print $1}')
kubectl exec -n urupix "$pod" -- sh -c 'ls -1 /app/uploads/voice 2>/dev/null | wc -l' 2>/dev/null \
  | sed 's/^/  mp3 em cache: /'

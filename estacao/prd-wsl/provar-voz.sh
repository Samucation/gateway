#!/usr/bin/env bash
# Gera áudio de verdade pelo caminho REAL: Urupix -> central-motor -> Kokoro.
#
# ⚠️ `/health` do motor responder 200 não prova voz nenhuma: ele responde 200
# com os motores desligados. A prova é BYTE DE ÁUDIO voltando.
set -uo pipefail

CHAVE=$(kubectl get secret urupix-secrets -n urupix -o jsonpath='{.data.CENTRAL_CHAVE}' 2>/dev/null | base64 -d)
[ -n "$CHAVE" ] || { echo "  ❌ nao achei CENTRAL_CHAVE no Secret do urupix"; exit 1; }

echo "== pedindo audio ao motor, com a chave do Urupix =="
saida=$(kubectl run vozteste$RANDOM -n urupix --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --quiet -- \
  -s -o /tmp/fala.mp3 -w '%{http_code} %{size_download} %{content_type}' --max-time 90 \
  -X POST "http://central-motor.central-ia.svc.cluster.local:3300/v1/audio/speech" \
  -H "Authorization: Bearer $CHAVE" -H 'Content-Type: application/json' \
  -d '{"model":"kokoro","voice":"pf_dora","input":"teste de voz da producao"}' 2>/dev/null | tr -d '\r')

cod=$(echo "$saida" | awk '{print $1}')
tam=$(echo "$saida" | awk '{print $2}')
tipo=$(echo "$saida" | awk '{print $3}')

echo "  codigo: ${cod:-000}   bytes: ${tam:-0}   tipo: ${tipo:-?}"
echo
if [ "${cod:-000}" = "200" ] && [ "${tam:-0}" -gt 1000 ]; then
  echo "  ✅ o motor gerou audio de verdade pelo caminho do Urupix"
  exit 0
fi
echo "  ❌ nao veio audio. 503 aqui significa motor SEM DESTINO (URL vazia),"
echo "     e nao motor caido -- os dois dao a mesma mensagem na tela."
exit 1

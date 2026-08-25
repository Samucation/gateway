#!/usr/bin/env bash
# O Chatterbox aceita, pelo nome do cluster, o corpo EXATO que o Urupix manda?
#
# ⚠️ Chamar `/tts` com um corpo qualquer não prova nada: sem
# `reference_audio_filename` ele devolve 400 e o teste "respondeu" — mas o app
# SEMPRE manda o arquivo de referência da voz clonada. Então o teste descobre
# um arquivo real no motor e usa esse.
set -uo pipefail
BASE=http://chatterbox.estacao.svc.cluster.local:8004

sonda() { # <metodo> <caminho> <corpo>
  kubectl run cb$RANDOM -n urupix --rm -i --restart=Never \
    --image=curlimages/curl:8.10.1 --quiet -- \
    -s --max-time 120 ${3:+-X POST -H 'Content-Type: application/json' -d "$3"} "$BASE$2" 2>/dev/null | tr -d '\r'
}

echo "== vozes de referencia que o motor tem =="
lista=$(sonda GET /get_reference_files "")
echo "  ${lista:0:200}"

ARQ=${1:-$(printf '%s' "$lista" | tr -d '[]" ' | tr ',' '\n' | head -1)}
[ -n "$ARQ" ] || { echo "  ❌ nao consegui descobrir um arquivo de referencia"; exit 1; }
echo "  usando: $ARQ"

corpo=$(printf '{"text":"teste de voz clonada da producao","voice_mode":"clone","reference_audio_filename":"%s","language":"pt","output_format":"mp3"}' "$ARQ")

echo
echo "== gerando =="
r=$(kubectl run cb$RANDOM -n urupix --rm -i --restart=Never \
    --image=curlimages/curl:8.10.1 --quiet -- \
    -s -o /tmp/cb.mp3 -w '%{http_code} %{size_download} %{content_type}' --max-time 180 \
    -X POST "$BASE/tts" -H 'Content-Type: application/json' -d "$corpo" 2>/dev/null | tr -d '\r')

cod=$(echo "$r" | awk '{print $1}'); tam=$(echo "$r" | awk '{print $2}')
echo "  codigo: ${cod:-000}  bytes: ${tam:-0}  tipo: $(echo "$r" | awk '{print $3}')"
if [ "${cod:-000}" = "200" ] && [ "${tam:-0}" -gt 1000 ]; then
  echo "  ✅ voz CLONADA gerada pelo nome do cluster"
else
  echo "  ❌ nao gerou"
fi

#!/usr/bin/env bash
# Como o app ENTREGA o mp3? (cabeçalhos que o tocador usa para saber o fim)
#
# ⚠️ Sem `Content-Length`, o Next responde em pedaços (chunked). Somado a um mp3
# SEM cabeçalho de duração (o Kokoro não escreve Xing/Info), o navegador fica
# sem nenhuma forma de saber quanto áudio existe — e o sintoma clássico disso é
# a última palavra sumindo.
set -uo pipefail
BASE=${BASE_URUPIX:-http://127.0.0.1:80}
HOST=${HOST_URUPIX:-urupix.com.br}

url=$(curl -s --max-time 90 -H "Host: $HOST" "$BASE/api/voice-preview/brasileira-clara" 2>/dev/null \
      | grep -oE '"audioUrl":"[^"]+"' | cut -d'"' -f4)
[ -n "$url" ] || { echo "  nao consegui gerar uma previa para medir"; exit 1; }
echo "  arquivo: $url"
echo
curl -s -D - -o /tmp/voz.mp3 --max-time 60 -H "Host: $HOST" "$BASE$url" 2>/dev/null \
  | grep -iE '^HTTP|^content-|^transfer-|^accept-ranges|^cache-' | sed 's/^/  /'
echo
echo "  bytes recebidos: $(wc -c < /tmp/voz.mp3)"

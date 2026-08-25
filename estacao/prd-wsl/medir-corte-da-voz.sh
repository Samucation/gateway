#!/usr/bin/env bash
# O motor entrega a frase INTEIRA, ou corta o final?
#
# Sintoma relatado: "obrigado por sua doação" saiu como "obrigado por sua doass"
# — ou seja, o áudio termina no meio da última palavra.
#
# ⚠️ Tamanho do mp3 é proxy de DURAÇÃO (bitrate fixo). Comparando a mesma frase
# com e sem o final, dá para ver se o motor está perdendo o fim: se acrescentar
# palavras ao texto NÃO aumenta o áudio, alguma coisa está cortando.
set -uo pipefail
MOTOR=${MOTOR:-http://kokoro.estacao.svc.cluster.local:8880}
VOZ=${VOZ:-pf_dora}

gerar() { # <rotulo> <texto>
  local r tam
  r=$(kubectl run medvoz$RANDOM -n central-ia --rm -i --restart=Never \
      --image=curlimages/curl:8.10.1 --quiet -- \
      -s -o /tmp/a.mp3 -w '%{size_download}' --max-time 120 \
      -X POST "$MOTOR/v1/audio/speech" -H 'Content-Type: application/json' \
      -d "{\"model\":\"kokoro\",\"voice\":\"$VOZ\",\"input\":\"$2\",\"response_format\":\"mp3\",\"lang_code\":\"p\"}" \
      2>/dev/null | tr -d '\r')
  printf '  %-52s %7s bytes   (%s caracteres)\n' "$1" "${r:-0}" "${#2}"
}

echo "== a MESMA frase, crescendo — o audio tem de crescer junto =="
gerar "so o comeco"            "Urupix mandou cinco reais."
gerar "+ saudacao"             "Urupix mandou cinco reais. Ola! Aqui e a voz Brasileira clara no Urupix."
gerar "+ agradecimento (tudo)" "Urupix mandou cinco reais. Ola! Aqui e a voz Brasileira clara no Urupix. Obrigado pela sua doacao!"

echo
echo "== a palavra sozinha, com e sem acento =="
gerar "doacao (sem acento)"    "Obrigado pela sua doacao."
gerar "doação (com acento)"    "Obrigado pela sua doação."
gerar "doação sem pontuacao"   "Obrigado pela sua doação"

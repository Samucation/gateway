#!/usr/bin/env bash
# As DUAS famílias de voz do Urupix, pelos caminhos que o código usa.
#
#   voz `neural`  ->  ${KOKORO_URL}/v1/audio/speech   (passa pela Central, com chave)
#   voz `clonada` ->  ${CHATTERBOX_URL}/tts           (NÃO passa pela Central)
#
# ⚠️ São dialetos diferentes. A Central fala `/v1/audio/speech` e NÃO conhece
# `/tts` -- apontar `CHATTERBOX_URL` para ela derruba só as vozes clonadas, e a
# tela mostra a mesma mensagem genérica dos dois casos.
set -uo pipefail

pod=$(kubectl get pods -n urupix -l app=urupix-app --no-headers 2>/dev/null | grep ' Running ' | head -1 | awk '{print $1}')
[ -n "$pod" ] || { echo "  sem Pod do urupix"; exit 1; }

K=$(kubectl exec -n urupix "$pod" -- printenv KOKORO_URL 2>/dev/null | tr -d '\r')
C=$(kubectl exec -n urupix "$pod" -- printenv CHATTERBOX_URL 2>/dev/null | tr -d '\r')
CH=$(kubectl exec -n urupix "$pod" -- printenv CENTRAL_CHAVE 2>/dev/null | tr -d '\r')

echo "== o que o Urupix tem =="
printf '  %-16s %s\n' "KOKORO_URL"     "${K:-(vazia)}"
printf '  %-16s %s\n' "CHATTERBOX_URL" "${C:-(vazia)}"
printf '  %-16s %s\n' "CENTRAL_CHAVE"  "$([ -n "$CH" ] && echo "presente (${#CH} caracteres)" || echo "(vazia)")"

testar() { # <rotulo> <url> <corpo> <cabecalho-extra>
  local r cod tam
  r=$(kubectl run vozu$RANDOM -n urupix --rm -i --restart=Never \
      --image=curlimages/curl:8.10.1 --quiet -- \
      -s -o /dev/null -w '%{http_code} %{size_download}' --max-time 90 \
      -X POST "$2" -H 'Content-Type: application/json' ${4:+-H "$4"} -d "$3" 2>/dev/null | tr -d '\r')
  cod=$(echo "$r" | awk '{print $1}'); tam=$(echo "$r" | awk '{print $2}')
  if [ "${cod:-000}" = "200" ] && [ "${tam:-0}" -gt 1000 ]; then
    printf '  %-34s %s  %s bytes  ✅ gerou audio\n' "$1" "$cod" "$tam"
  else
    printf '  %-34s %s  %s bytes  ❌\n' "$1" "${cod:-000}" "${tam:-0}"
  fi
}

echo
echo "== voz NEURAL (Kokoro, pela Central) =="
testar "POST \$KOKORO_URL/v1/audio/speech" \
  "${K:-http://localhost:8880}/v1/audio/speech" \
  '{"model":"kokoro","voice":"pf_dora","input":"teste de voz neural","response_format":"mp3"}' \
  "${CH:+Authorization: Bearer $CH}"

echo
echo "== voz CLONADA (Chatterbox, direto) =="
# ⚠️ `reference_audio_filename` é OBRIGATÓRIO com `voice_mode: clone` -- sem ele
# o motor devolve 400.
#
# 🐞 A primeira versão deste teste mandava só `{"text": ...}` e levava 400. Com o
# destino JÁ corrigido, o 400 continuava aparecendo e parecia que a correção não
# tinha pegado. Teste que falha por culpa própria é pior que teste nenhum: ele
# desmente um conserto que funcionou.
#
# O arquivo vem do próprio motor, para o teste não depender de nome chumbado.
REF=${REF_CLONE:-$(kubectl run ref$RANDOM -n urupix --rm -i --restart=Never \
      --image=curlimages/curl:8.10.1 --quiet -- \
      -s --max-time 20 "${C:-http://localhost:8004}/get_reference_files" 2>/dev/null \
      | tr -d '[]"\r ' | tr ',' '\n' | head -1)}
echo "  voz de referencia: ${REF:-(nao descobri)}"

testar "POST \$CHATTERBOX_URL/tts" \
  "${C:-http://localhost:8004}/tts" \
  "{\"text\":\"teste de voz clonada\",\"voice_mode\":\"clone\",\"reference_audio_filename\":\"$REF\",\"language\":\"pt\",\"output_format\":\"mp3\"}" \
  ""

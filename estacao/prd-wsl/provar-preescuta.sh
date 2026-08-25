#!/usr/bin/env bash
# A PRÉVIA PÚBLICA de voz do Urupix gera áudio de verdade?
#
# Esta é a prova que faltava. As anteriores chamavam os MOTORES direto; esta
# chama a rota da aplicação (`/api/voice-preview/<voz>`), que passa por
# `generateVoiceAudio` — o mesmo código que o overlay usa.
#
# ⚠️ É por aqui que se distingue "motor bom" de "app conseguindo usar o motor":
# tudo o que está no meio (mapeamento da voz, trava no Redis, gravação em disco,
# cache por hash) só é exercitado deste lado.
#
# A rota é pública (tem teto por IP), então não precisa de sessão.
set -uo pipefail
BASE=${BASE_URUPIX:-http://127.0.0.1:80}
HOST=${HOST_URUPIX:-urupix.com.br}

testar() { # <voz> <familia>
  local corpo cod url
  corpo=$(curl -s --max-time 90 -H "Host: $HOST" "$BASE/api/voice-preview/$1" 2>/dev/null)
  cod=$(curl -s -o /dev/null -w '%{http_code}' --max-time 90 -H "Host: $HOST" "$BASE/api/voice-preview/$1" 2>/dev/null)
  url=$(printf '%s' "$corpo" | grep -oE '"audioUrl":"[^"]+"' | cut -d'"' -f4)

  if [ -n "$url" ]; then
    # ⚠️ A URL existir não prova que o arquivo TOCA. Busca o mp3 e mede.
    local tam
    tam=$(curl -s -o /dev/null -w '%{size_download}' --max-time 60 -H "Host: $HOST" "$BASE$url" 2>/dev/null)
    printf '  %-14s %-9s %s  %s bytes  %s\n' "$1" "$2" "$cod" "$tam" \
      "$([ "${tam:-0}" -gt 1000 ] && echo '✅ audio real' || echo '❌ arquivo vazio')"
  else
    printf '  %-14s %-9s %s  SEM audioUrl  ❌ %s\n' "$1" "$2" "$cod" \
      "$(printf '%s' "$corpo" | head -c 70)"
  fi
}

echo "== prévia pública, pela rota da APLICAÇÃO =="
for par in "$@"; do
  testar "${par%%:*}" "${par##*:}"
done

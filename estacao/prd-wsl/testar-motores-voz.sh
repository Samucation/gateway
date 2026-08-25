#!/usr/bin/env bash
# Os motores de voz respondem de dentro do cluster, nos caminhos REAIS deles?
#
# ⚠️ Perguntar em `/` engana: o Kokoro devolve 404 ali e o Chatterbox 200, e
# nenhum dos dois diz nada sobre o motor estar pronto. Cada um tem o seu
# caminho de saude, e é por ele que se pergunta.
set -uo pipefail

medir() { # <rotulo> <url>
  local c
  c=$(kubectl run sonda-$RANDOM -n central-ia --rm -i --restart=Never \
        --image=curlimages/curl:8.10.1 --quiet -- \
        -s -o /dev/null -w '%{http_code}' --max-time 12 "$2" 2>/dev/null | tr -d '\r')
  printf '  %-52s %s\n' "$1" "${c:-000}"
}

medir "kokoro      /health"          "http://kokoro.estacao.svc.cluster.local:8880/health"
medir "kokoro      /v1/audio/voices" "http://kokoro.estacao.svc.cluster.local:8880/v1/audio/voices"
medir "chatterbox  /"                "http://chatterbox.estacao.svc.cluster.local:8004/"
medir "whisper     /health"          "http://whisper.estacao.svc.cluster.local:8040/health"

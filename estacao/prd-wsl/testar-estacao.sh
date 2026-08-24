#!/usr/bin/env bash
# Confere os nomes do namespace `estacao` de dentro do cluster.
set -uo pipefail
for par in sandbox-sigma:3201 chatterbox:8004 kokoro:8880 whisper:8040; do
  nome=${par%%:*}; porta=${par##*:}
  cod=$(kubectl run t$RANDOM --rm -i --restart=Never --image=curlimages/curl:8.10.1 --quiet -- \
        -s -o /dev/null -w '%{http_code}' --max-time 10 \
        "http://$nome.estacao.svc.cluster.local:$porta/" 2>/dev/null | tr -d '\r')
  printf '  %-16s :%-5s %s\n' "$nome" "$porta" "${cod:-000}"
done

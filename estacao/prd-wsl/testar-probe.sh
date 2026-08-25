#!/usr/bin/env bash
# A probe do Pod responde quando perguntada DE DENTRO do próprio Pod?
#
#     bash testar-probe.sh <ns> <app> [caminho] [porta]
#
# ⚠️ "Startup probe failed" com o app dizendo "Ready" quer dizer que o processo
# subiu e a ROTA da probe não responde a tempo — coisa diferente de app caído.
# Perguntando de dentro, tira-se a rede do meio.
set -uo pipefail
ns="$1"; app="$2"; caminho="${3:-/}"; porta="${4:-3100}"
pod=$(kubectl get pods -n "$ns" -l app="$app" --no-headers 2>/dev/null | tail -1 | awk '{print $1}')
echo "  pod: ${pod:-nenhum}"
[ -n "$pod" ] || exit 1

echo "  == a probe declarada =="
kubectl get pod -n "$ns" "$pod" -o jsonpath='    startup: {.spec.containers[0].startupProbe.httpGet.path} porta {.spec.containers[0].startupProbe.httpGet.port} periodo {.spec.containers[0].startupProbe.periodSeconds}s tentativas {.spec.containers[0].startupProbe.failureThreshold} tempo {.spec.containers[0].startupProbe.timeoutSeconds}s{"\n"}' 2>/dev/null

echo "  == volumes montados (um volume por cima do lugar errado quebra a partida) =="
kubectl get pod -n "$ns" "$pod" -o jsonpath='{range .spec.containers[0].volumeMounts[*]}    {.mountPath}{"\n"}{end}' 2>/dev/null

echo "  == perguntando de DENTRO do Pod, com tempo generoso =="
kubectl exec -n "$ns" "$pod" -- sh -c \
  "command -v wget >/dev/null && wget -q -S -O /dev/null -T 25 http://127.0.0.1:$porta$caminho 2>&1 | head -4 || echo '    (sem wget na imagem)'" 2>&1 | sed 's/^/    /'

#!/usr/bin/env bash
# Por que um Pod específico não sobe.
#     bash ver-pod.sh <ns> <prefixo-do-nome>
set -uo pipefail
ns="$1"; pref="$2"
pod=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep "^$pref" | tail -1 | awk '{print $1}')
echo "  pod: ${pod:-nenhum}"
[ -n "$pod" ] || exit 1

kubectl get pod -n "$ns" "$pod" --no-headers 2>/dev/null | sed 's/^/  /'
echo
echo "  == estado do container =="
kubectl get pod -n "$ns" "$pod" -o jsonpath='    reason={.status.containerStatuses[0].state.*.reason}{"\n"}    exit={.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}    msg={.status.containerStatuses[0].lastState.terminated.message}{"\n"}' 2>/dev/null

echo "  == ultimos eventos =="
kubectl get events -n "$ns" --field-selector involvedObject.name="$pod" --sort-by=.lastTimestamp 2>/dev/null \
  | tail -6 | cut -c1-135 | sed 's/^/    /'

echo "  == log =="
kubectl logs -n "$ns" "$pod" --tail=12 2>&1 | cut -c1-135 | sed 's/^/    /'
kubectl logs -n "$ns" "$pod" --previous --tail=8 2>/dev/null | cut -c1-135 | sed 's/^/    (anterior) /'

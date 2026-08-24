#!/usr/bin/env bash
# O log do Pod mais recente do nfe-service, filtrado pelo que importa.
set -uo pipefail
p=$(kubectl get pods -n veltrixa -l app=veltrixa-nfe-service --sort-by=.status.startTime --no-headers 2>/dev/null | tail -1 | awk '{print $1}')
echo "  pod: ${p:-nenhum}  estado: $(kubectl get pod -n veltrixa "$p" -o jsonpath='{.status.phase}' 2>/dev/null)"
[ -n "$p" ] || exit 1
kubectl logs -n veltrixa "$p" --tail=60 2>&1 \
  | grep -iE 'checksum|migrating|successfully applied|current version|Started NfeService|APPLICATION FAILED|Caused by' \
  | head -14 | sed 's/^/    /'

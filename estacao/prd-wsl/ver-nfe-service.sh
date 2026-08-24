#!/usr/bin/env bash
# Por que o `veltrixa-nfe-service` nao completa o rollout.
set -uo pipefail
echo "== Pods =="
kubectl get pods -n veltrixa -l app=veltrixa-nfe-service --no-headers 2>/dev/null \
  | awk '{printf "  %-42s %-8s %-22s reinicios=%s  %s\n", $1, $2, $3, $4, $5}'
echo
echo "== por que nao fica pronto =="
pod=$(kubectl get pods -n veltrixa -l app=veltrixa-nfe-service --no-headers 2>/dev/null | tail -1 | awk '{print $1}')
if [ -n "$pod" ]; then
  kubectl describe pod -n veltrixa "$pod" 2>/dev/null \
    | grep -A 6 -E '^\s*(Warning|State|Last State|Ready|Restart Count)' | head -30 | sed 's/^/  /'
  echo
  echo "== log do container =="
  kubectl logs -n veltrixa "$pod" --tail=25 2>&1 | sed 's/^/    /'
fi
echo
echo "== memoria/cpu pedidos e limites =="
kubectl get deploy veltrixa-nfe-service -n veltrixa \
  -o jsonpath='  requests={.spec.template.spec.containers[0].resources.requests}{"\n"}  limits={.spec.template.spec.containers[0].resources.limits}{"\n"}' 2>/dev/null

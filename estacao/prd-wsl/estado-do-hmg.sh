#!/usr/bin/env bash
# Retrato da HOMOLOGAÇÃO (k3d, dentro do Docker Desktop).
#
# ⚠️ As etapas de homologação das esteiras terminam em 0 segundo. Ou o cluster
# está vazio e elas não fazem nada, ou fazem e não esperam. Este script mostra o
# que está REALMENTE lá.
set -uo pipefail
K="kubectl --kubeconfig=/var/lib/jenkins/.kube/config-hmg"

echo "== no =="
$K get nodes --no-headers 2>&1 | awk '{printf "  %-20s %s  %s\n", $1, $2, $5}'

echo
echo "== namespaces com carga =="
$K get deploy,statefulset -A --no-headers 2>/dev/null \
  | grep -vE '^kube-system' | awk '{printf "  %-16s %-34s %s\n", $1, $2, $3}'

echo
echo "== Pods fora do ar =="
fora=$($K get pods -A --no-headers 2>/dev/null | grep -vE ' Running | Completed ' | wc -l)
todos=$($K get pods -A --no-headers 2>/dev/null | wc -l)
echo "  $((todos - fora)) de $todos rodando"
[ "$fora" -gt 0 ] && $K get pods -A --no-headers 2>/dev/null | grep -vE ' Running | Completed ' \
  | awk '{printf "     %-14s %-38s %s\n", $1, $2, $4}'

echo
echo "== dominios de homologacao =="
$K get ingress -A -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}' 2>/dev/null \
  | sort -u | sed 's/^/  /'

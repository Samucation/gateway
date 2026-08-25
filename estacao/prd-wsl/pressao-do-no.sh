#!/usr/bin/env bash
# O nó está sob pressão? (partida em massa depois de um reinício)
#
# ⚠️ Depois que a distro reinicia, TODOS os Pods sobem ao mesmo tempo — inclusive
# os pesados (SonarQube, Keycloak, três Postgres, os apps Java). O nó fica sem
# CPU para todo mundo, as probes de partida estouram, o Kubernetes mata e
# reinicia — e o laço se realimenta.
set -uo pipefail

echo "== memoria e carga do no =="
free -h 2>/dev/null | sed -n '1,2p' | sed 's/^/  /'
echo "  carga: $(uptime | sed 's/.*load average: //')"
echo "  nucleos: $(nproc)"

echo
echo "== o que o Kubernetes ja PROMETEU (requests) =="
kubectl describe node 2>/dev/null | sed -n '/Allocated resources/,/Events/p' \
  | grep -E 'cpu|memory' | head -4 | sed 's/^/  /'

echo
echo "== quem foi MORTO por memoria =="
mortos=$(kubectl get pods -A -o json 2>/dev/null \
  | grep -c OOMKilled)
echo "  containers com OOMKilled no historico: ${mortos:-0}"

echo
echo "== Pods Running mas NAO prontos (probe recusando) =="
kubectl get pods -A --no-headers 2>/dev/null \
  | awk '$3 == "Running" {split($2,a,"/"); if (a[1] != a[2]) printf "  %-16s %-44s %s\n", $1, $2, $2}' \
  | head -14

echo
echo "== os 6 que mais consomem =="
kubectl top pods -A --no-headers 2>/dev/null | sort -k3 -hr | head -6 \
  | awk '{printf "  %-16s %-40s cpu=%-8s mem=%s\n", $1, $2, $3, $4}' \
  || echo "  (metrics-server ainda nao respondeu)"

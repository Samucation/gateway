#!/usr/bin/env bash
# Retrato da produção em uma tela: Pods, entrada, domínios e esteiras.
#
#     wsl -d prd -u root -- bash .../estado-da-producao.sh
#
# ⚠️ Mede o que se pode medir de dentro da distro. O que só se vê de fora (o
# túnel, o DNS da Cloudflare) fica para o `PENDENTE-ELEVACAO.ps1` e para o
# `curl` no PowerShell — dizer "produção ok" olhando só para dentro já enganou
# antes: os Pods estavam perfeitos e o domínio devolvia 502.
set -uo pipefail

echo "== Pods =="
total=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l)
rodando=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c ' Running ')
ruins=$(kubectl get pods -A --no-headers 2>/dev/null | grep -vE ' Running | Completed ' | wc -l)
echo "  $rodando de $total rodando"
if [ "$ruins" -gt 0 ]; then
  echo "  ⚠️ fora do ar:"
  kubectl get pods -A --no-headers | grep -vE ' Running | Completed ' | awk '{printf "     %-18s %-34s %s\n", $1, $2, $4}'
fi

echo
echo "== quem esta na entrada =="
kubectl get deploy kong -n gateway -o jsonpath='  kong: {.status.readyReplicas}/{.spec.replicas} pronto, portas do no {.spec.template.spec.containers[0].ports[*].hostPort}{"\n"}' 2>/dev/null
echo "  traefik: $(kubectl get svc traefik -n kube-system -o jsonpath='{.spec.type}') (ClusterIP = soltou a porta do no, e o certo)"

echo
echo "== dominios, pela entrada de verdade =="
bash "$(dirname "${BASH_SOURCE[0]}")/conferir-kong.sh" --pela-entrada 2>/dev/null | grep -vE '^==|^$'

echo
echo "== esteiras =="
bash "$(dirname "${BASH_SOURCE[0]}")/esteira.sh" estado 2>/dev/null

#!/usr/bin/env bash
# Por que as tarefas agendadas do Urupix morreram — e QUANDO.
#
# ⚠️ Pod em `Error` na lista nem sempre e problema de agora: o Kubernetes
# guarda um historico de falhas (`failedJobsHistoryLimit`). Olhar so o
# `kubectl get pods` faz falha velha parecer pane em curso.
set -uo pipefail

echo "== CronJobs =="
kubectl get cronjob -n urupix -o custom-columns=\
'NOME:.metadata.name,AGENDA:.spec.schedule,SUSPENSO:.spec.suspend,ULTIMO:.status.lastSuccessfulTime' \
  --no-headers 2>/dev/null | awk '{printf "  %-30s %-14s suspenso=%-6s ultimo sucesso=%s\n", $1, $2, $3, $4}'

echo
echo "== Pods com falha, do mais novo para o mais velho =="
kubectl get pods -n urupix --no-headers 2>/dev/null | grep -E ' Error | Failed ' \
  | awk '{print $1}' | while IFS= read -r p; do
  quando=$(kubectl get pod -n urupix "$p" -o jsonpath='{.status.startTime}' 2>/dev/null)
  motivo=$(kubectl logs -n urupix "$p" --tail=3 2>&1 | tr '\n' ' ' | cut -c1-96)
  printf '  %-42s %s\n      %s\n' "$p" "$quando" "$motivo"
done

echo
echo "== ultima execucao de cada uma =="
for j in urupix-disparo-de-avisos urupix-fila-de-entrega urupix-vigia-de-live; do
  pod=$(kubectl get pods -n urupix --sort-by=.status.startTime --no-headers 2>/dev/null \
        | grep "^$j" | tail -1 | awk '{print $1}')
  [ -n "$pod" ] || continue
  printf '  %-30s %s\n' "$j" "$(kubectl logs -n urupix "$pod" --tail=1 2>&1 | cut -c1-100)"
done

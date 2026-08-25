#!/usr/bin/env bash
# O que ainda não subiu, e por quê — depois de um reinício da distro.
#
# ⚠️ Pod em `ContainerCreating` é normal por alguns minutos; parado nisso por
# mais que isso é volume que não monta ou imagem que não baixa. `Error` de
# CronJob é histórico. O que importa é Deployment com réplica faltando.
set -uo pipefail

echo "== Deployments incompletos =="
# 🐞 A coluna READY vem como FRAÇÃO ("1/1"), e a de UP-TO-DATE como número
# ("1"). Comparar as duas direto dá sempre diferente — a primeira versão deste
# script listou os 28 Deployments do cluster como "incompletos" com tudo no ar,
# e eu quase saí consertando o que não estava quebrado.
#
# ⚠️ Lista de problemas que inclui todo mundo é igual a lista nenhuma: ela para
# de distinguir e passa a ser ignorada.
kubectl get deploy -A --no-headers 2>/dev/null \
  | awk '{split($3,a,"/"); if (a[1] != a[2]) printf "  %-16s %-30s pronto=%s\n", $1, $2, $3}'

echo
echo "== StatefulSets incompletos =="
kubectl get statefulset -A --no-headers 2>/dev/null \
  | awk '{split($3,a,"/"); if (a[1] != a[2]) printf "  %-16s %-30s %s\n", $1, $2, $3}'

echo
echo "== Pods que nao sao de CronJob e nao estao Running =="
kubectl get pods -A --no-headers 2>/dev/null \
  | grep -vE ' Running | Completed ' \
  | grep -vE 'disparo-de-avisos|fila-de-entrega|vigia-de-live|sync-noturno|backup' \
  | awk '{printf "  %-16s %-42s %-24s %s\n", $1, $2, $4, $6}'

echo
echo "== motivo dos que estao presos =="
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null \
  | grep -vE 'disparo-de-avisos|fila-de-entrega|vigia-de-live' \
  | tail -8 | cut -c1-140 | sed 's/^/  /'

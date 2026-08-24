#!/usr/bin/env bash
# Lista os Services do k3s com porta — é o cardápio de destinos do Kong.
#
# ⚠️ Em ARQUIVO. Inline dentro de `wsl.exe -- bash -c "..."` o `$1` do awk é
# comido pelo shell do Windows e vira `{printf "%s", , }` — erro de sintaxe.
set -uo pipefail
kubectl get svc -A --no-headers \
  | grep -vE '^kube-system|^default +kubernetes' \
  | awk '{printf "  %-16s %-28s %s\n", $1, $2, $6}'

#!/usr/bin/env bash
# O que o Pod REALMENTE recebe, e não o que o Secret declara.
#
#     bash env-efetivo.sh <ns> <app> <filtro>
#
# ⚠️ `env` no Deployment sobrescreve `envFrom` do Secret. Ler só o Secret pode
# apontar um defeito que não existe -- ou esconder um que existe.
set -uo pipefail
ns="$1"; app="$2"; filtro="${3:-.}"
pod=$(kubectl get pods -n "$ns" -l app="$app" --no-headers 2>/dev/null | grep ' Running ' | head -1 | awk '{print $1}')
[ -n "$pod" ] || { echo "  sem Pod rodando em $ns/$app"; exit 1; }
echo "  pod: $pod"
kubectl exec -n "$ns" "$pod" -- env 2>/dev/null \
  | grep -iE "$filtro" | sort \
  | sed -E 's#(://[^:/@]+:)[^@]+@#\1***@#' \
  | sed 's/^/    /'

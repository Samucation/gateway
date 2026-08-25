#!/usr/bin/env bash
# O log do Pod de uma aplicação, filtrado pelo que interessa.
#     bash log-app.sh <ns> <app> [padrao] [linhas]
#
# ⚠️ Em ARQUIVO. Inline dentro de `wsl.exe -- bash -c "..."` as aspas do `awk`
# são comidas e o erro que sai é "unterminated string", que não tem nada a ver
# com o problema que se está investigando.
#
# ⚠️ E o padrão NÃO vai por argumento com `|` dentro: a barra vertical é
# interpretada pelo shell do Windows ANTES de chegar aqui, e cada alternativa
# vira um comando — "erro: command not found". O padrão de problemas mora aqui
# dentro; o argumento aceita uma palavra só.
set -uo pipefail
PROBLEMAS='error|erro|falha|failed|warn|exception|refused|denied|timeout'
ns="$1"; app="$2"; padrao="${3:-$PROBLEMAS}"; n="${4:-200}"
pod=$(kubectl get pods -n "$ns" -l app="$app" --sort-by=.status.startTime --no-headers 2>/dev/null \
      | grep ' Running ' | tail -1 | awk '{print $1}')
echo "  pod: ${pod:-nenhum}"
[ -n "$pod" ] || exit 1
kubectl logs -n "$ns" "$pod" --tail="$n" 2>&1 | grep -iE "$padrao" | tail -20 | cut -c1-150 | sed 's/^/    /'

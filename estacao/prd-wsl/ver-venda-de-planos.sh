#!/usr/bin/env bash
# A venda de planos está LIGADA? O app diz na partida, numa linha só.
#
# ⚠️ Sem as variáveis do sigma-financeiro o app NÃO falha: ele escreve
# "Venda de planos DESLIGADA: faltam ..." e segue de pé. Pod pronto, probe
# verde, domínio 200 — e ninguém consegue comprar.
set -uo pipefail
for par in opuschat:opuschat-app plataforma:plataforma-app; do
  ns=${par%%:*}; app=${par##*:}
  pod=$(kubectl get pods -n "$ns" -l app="$app" --no-headers 2>/dev/null | grep ' Running ' | head -1 | awk '{print $1}')
  [ -n "$pod" ] || { printf '  %-12s sem Pod rodando\n' "$ns"; continue; }
  url=$(kubectl exec -n "$ns" "$pod" -- printenv SIGMA_FINANCEIRO_URL 2>/dev/null | tr -d '\r')
  linha=$(kubectl logs -n "$ns" "$pod" --tail=400 2>/dev/null | grep -i 'venda de planos' | tail -1 | cut -c1-70)
  printf '  %-12s URL=%s\n' "$ns" "${url:-(nao definida)}"
  printf '  %-12s log: %s\n' "" "${linha:-(nada sobre venda de planos no log recente)}"
done

#!/usr/bin/env bash
# Estado do sigma-financeiro em produção — SÓ LEITURA.
#
# ⚠️ REGRA DE OURO: este projeto é somente leitura. Aqui só há `SELECT` e
# consulta de estado; nada altera dado, configuração ou objeto do cluster.
#
# A pergunta que interessa não é "o Pod está no ar": é se ele está carimbado
# como PRODUÇÃO e se o Mercado Pago está utilizável. O serviço confere o
# ambiente DENTRO do banco e se recusa a subir se discordar da variável —
# então "subiu" já diz alguma coisa, mas não diz tudo.
set -uo pipefail
NS=sigma-financeiro

echo "== Pods =="
kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '{printf "  %-40s %-8s %-12s %s\n", $1, $2, $3, $5}'

echo
echo "== ambiente que o Pod declara =="
pod=$(kubectl get pods -n "$NS" -l app=sigma-financeiro --no-headers 2>/dev/null | grep ' Running ' | tail -1 | awk '{print $1}')
if [ -n "$pod" ]; then
  for v in NODE_ENV SIGMA_AMBIENTE AMBIENTE APP_ENV; do
    val=$(kubectl exec -n "$NS" "$pod" -- printenv "$v" 2>/dev/null | tr -d '\r')
    [ -n "$val" ] && printf '  %-16s %s\n' "$v" "$val"
  done
  # A URL do banco diz para QUAL base ele aponta (produção x sandbox), sem senha.
  kubectl exec -n "$NS" "$pod" -- printenv DATABASE_URL 2>/dev/null \
    | sed -E 's#://[^:]+:[^@]+@#://***:***@#' | sed 's/^/  DATABASE_URL     /'
fi

echo
echo "== o serviço responde? =="
for caminho in / /api/health /api/status; do
  c=$(kubectl run sfin$RANDOM -n "$NS" --rm -i --restart=Never --image=curlimages/curl:8.10.1 --quiet -- \
      -s -o /dev/null -w '%{http_code}' --max-time 15 \
      "http://sigma-financeiro.$NS.svc.cluster.local:3200$caminho" 2>/dev/null | tr -d '\r')
  printf '  %-16s %s\n' "$caminho" "${c:-000}"
done

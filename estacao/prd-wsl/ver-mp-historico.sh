#!/usr/bin/env bash
# O histórico REAL de cobranças do Mercado Pago — só leitura, só agregado.
#
# ⚠️ A tabela é `Charge`, não "cobranca". E aqui só se conta e se agrupa: nada
# de listar valor, pagador ou documento. Consultar dado de cliente para saber se
# o sistema funciona é legítimo; expor esse dado num log não é.
set -uo pipefail
NS=sigma-financeiro
DB=${POD_DB:-sigma-db-0}
le() { kubectl exec -n "$NS" "$DB" -- psql -U sigma -d sigma_financeiro -tAc "$1" 2>/dev/null | tr -d '\r'; }

echo "== cobrancas por provedor e situacao =="
le "SELECT '  ' || rpad(COALESCE(provider::text,'?'), 16) || rpad(COALESCE(status::text,'?'), 14) || count(*)
    FROM \"Charge\" GROUP BY provider, status ORDER BY count(*) DESC LIMIT 12"

echo
echo "== a ultima do Mercado Pago que chegou a ser paga =="
le "SELECT '  ' || COALESCE(max(\"updatedAt\")::text, '(nenhuma)')
    FROM \"Charge\" WHERE provider::text ILIKE '%MERCADO%'
      AND status::text IN ('PAID','APPROVED','PAGA','PAGO','approved','paid')"

echo
echo "== comprovantes guardados (a prova de que o dinheiro entrou) =="
le "SELECT '  ' || count(*) || ' comprovante(s)' FROM \"ComprovanteDePagamento\""

echo
echo "== assinaturas ativas =="
le "SELECT '  ' || COALESCE(status::text,'?') || ': ' || count(*) FROM \"Subscription\" GROUP BY status"

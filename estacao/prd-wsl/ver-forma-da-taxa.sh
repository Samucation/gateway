#!/usr/bin/env bash
# A taxa do Mercado Pago é PERCENTUAL pura, ou tem parte fixa?
#
# A diferença importa para projetar: 1% puro em R$ 100 são R$ 1,00; 1% + R$ 0,40
# fixos seriam R$ 1,40. Com valores pequenos (R$ 1 a R$ 10) as duas hipóteses
# parecem quase iguais — só o par (bruto, taxa) separa.
#
# ⚠️ Só agregado por VALOR, sem identificar cobrança.
set -uo pipefail
NS=sigma-financeiro
DB=${POD_DB:-sigma-db-0}
le() { kubectl exec -n "$NS" "$DB" -- psql -U sigma -d sigma_financeiro -tAc "$1" 2>/dev/null | tr -d '\r'; }

echo "== par (valor cobrado, taxa do MP) =="
le "SELECT '  R\$ ' || rpad(round(\"amountCents\"/100.0,2)::text, 8) ||
           ' -> taxa R\$ ' || rpad(round(\"providerFeeCents\"/100.0,2)::text, 7) ||
           ' = ' || round(100.0 * \"providerFeeCents\" / NULLIF(\"amountCents\",0), 3)::text || '%' ||
           '   (' || count(*) || 'x)'
    FROM \"Charge\"
    WHERE status::text IN ('paid','PAID','approved') AND COALESCE(\"providerFeeCents\",0) > 0
    GROUP BY \"amountCents\", \"providerFeeCents\"
    ORDER BY \"amountCents\""

echo
echo "== a taxa esperada declarada no proprio servico =="
le "SELECT '  ' || column_name FROM information_schema.columns
    WHERE table_name='Settings' AND (column_name ILIKE '%taxa%' OR column_name ILIKE '%fee%')"

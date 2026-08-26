#!/usr/bin/env bash
# Qual o PERFIL de valor das cobranças? — decide se taxa fixa faz sentido.
#
# ⚠️ Taxa fixa e taxa percentual são coisas diferentes conforme o ticket. R$ 0,40
# fixos em R$ 100 são 0,4%; nos mesmos R$ 0,40 sobre R$ 2,00 são 20%. Recomendar
# modelo de cobrança sem olhar o ticket é chutar.
set -uo pipefail
NS=sigma-financeiro
DB=${POD_DB:-sigma-db-0}
le() { kubectl exec -n "$NS" "$DB" -- psql -U sigma -d sigma_financeiro -tAc "$1" 2>/dev/null | tr -d '\r'; }

echo "== distribuicao dos valores JA cobrados =="
le "SELECT '  ' || rpad(faixa, 18) || count(*) || ' cobranca(s)'
    FROM (
      SELECT CASE
        WHEN \"amountCents\" <  500  THEN 'ate R\$ 5'
        WHEN \"amountCents\" < 2000  THEN 'R\$ 5 a 20'
        WHEN \"amountCents\" < 10000 THEN 'R\$ 20 a 100'
        ELSE 'acima de R\$ 100'
      END AS faixa
      FROM \"Charge\" WHERE status::text IN ('paid','PAID','approved')
    ) t GROUP BY faixa ORDER BY faixa"

echo
echo "== o que a plataforma ARRECADARIA com cada modelo (sobre o que ja passou) =="
le "SELECT '  volume total: R\$ ' || round(sum(\"amountCents\")/100.0,2)::text ||
           '   ticket medio: R\$ ' || round(avg(\"amountCents\")/100.0,2)::text
    FROM \"Charge\" WHERE status::text IN ('paid','PAID','approved')"
le "SELECT '  1,00% do volume ......... R\$ ' || round(sum(\"amountCents\")*0.01/100.0, 2)::text
    FROM \"Charge\" WHERE status::text IN ('paid','PAID','approved')"
le "SELECT '  R\$ 0,40 por transacao ... R\$ ' || round(count(*)*0.40, 2)::text ||
           '   (= ' || round(100.0*count(*)*40/NULLIF(sum(\"amountCents\"),0), 1)::text || '% do volume)'
    FROM \"Charge\" WHERE status::text IN ('paid','PAID','approved')"

echo
echo "== saques ja feitos (custo que a plataforma carrega) =="
le "SELECT '  ' || count(*) || ' saque(s)' FROM \"Payout\""

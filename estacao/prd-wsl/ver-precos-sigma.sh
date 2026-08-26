#!/usr/bin/env bash
# A tabela de preços da PLATAFORMA (o que o Sigma cobra) — só leitura.
#
# `PrecoDoSigma` tem escopo/alvo/provider/metodo, e três componentes:
#   percentualBps  em pontos-base (100 bps = 1%)
#   fixoCents      valor fixo por transação
#   tetoCents      teto do percentual (0 = sem teto)
set -uo pipefail
NS=sigma-financeiro
DB=${POD_DB:-sigma-db-0}
le() { kubectl exec -n "$NS" "$DB" -- psql -U sigma -d sigma_financeiro -tAc "$1" 2>/dev/null | tr -d '\r'; }

echo "== precos configurados (o que a PLATAFORMA cobra) =="
n=$(le "SELECT count(*) FROM \"PrecoDoSigma\" WHERE ativo = true")
echo "  regras ativas: ${n:-0}"
le "SELECT '  ' || rpad(escopo,10) || rpad(COALESCE(alvo,'-'),22) || rpad(COALESCE(provider,'todos'),16) ||
           rpad(COALESCE(metodo,'todos'),10) ||
           (\"percentualBps\"::numeric/100)::text || '%  + R\$ ' ||
           (\"fixoCents\"::numeric/100)::text ||
           CASE WHEN \"tetoCents\" > 0 THEN '  teto R\$ ' || (\"tetoCents\"::numeric/100)::text ELSE '' END
    FROM \"PrecoDoSigma\" WHERE ativo = true
    ORDER BY escopo, COALESCE(provider,''), COALESCE(metodo,'')"

echo
echo "== o que ja foi COBRADO de verdade (amostra agregada) =="
# ⚠️ Agregado, nunca linha a linha: saber quanto o sistema cobra nao exige
# expor cobranca de cliente.
le "SELECT '  ' || rpad(COALESCE(provider::text,'?'),16) || rpad(COALESCE(method::text,'?'),10) ||
           count(*) || ' cobranca(s)'
    FROM \"Charge\" WHERE status::text IN ('paid','PAID','approved')
    GROUP BY provider, method"

echo
echo "== colunas de valor/taxa na Charge (para saber o que e registrado) =="
le "SELECT '  ' || column_name || ' (' || data_type || ')'
    FROM information_schema.columns
    WHERE table_name = 'Charge'
      AND (column_name ILIKE '%amount%' OR column_name ILIKE '%fee%' OR column_name ILIKE '%taxa%'
           OR column_name ILIKE '%liquido%' OR column_name ILIKE '%net%' OR column_name ILIKE '%split%')
    ORDER BY column_name"

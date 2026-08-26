#!/usr/bin/env bash
# As taxas REAIS das cobranças que já aconteceram — só leitura, agregado.
#
# A `Charge` guarda as duas separadas, e é isso que responde a pergunta:
#   providerFeeCents  o que o Mercado Pago ficou
#   sigmaFeeCents     o que a plataforma ficou
#
# ⚠️ Agregado por faixa de valor, nunca linha a linha: saber quanto o sistema
# cobra não exige expor cobrança de cliente.
set -uo pipefail
NS=sigma-financeiro
DB=${POD_DB:-sigma-db-0}
le() { kubectl exec -n "$NS" "$DB" -- psql -U sigma -d sigma_financeiro -tAc "$1" 2>/dev/null | tr -d '\r'; }

echo "== taxa efetiva das cobrancas PAGAS =="
le "SELECT '  ' || rpad(provider::text,15) || rpad(method::text,6) ||
           'n=' || rpad(count(*)::text,4) ||
           ' bruto medio R\$ ' || rpad(round(avg(\"amountCents\")/100.0, 2)::text, 9) ||
           ' MP R\$ ' || rpad(round(avg(\"providerFeeCents\")/100.0, 2)::text, 7) ||
           ' (' || round(100.0 * sum(\"providerFeeCents\") / NULLIF(sum(\"amountCents\"),0), 2)::text || '%)' ||
           ' sigma R\$ ' || round(avg(\"sigmaFeeCents\")/100.0, 2)::text
    FROM \"Charge\"
    WHERE status::text IN ('paid','PAID','approved')
    GROUP BY provider, method"

echo
echo "== quantas registraram taxa do provedor? =="
le "SELECT '  com taxa do MP registrada: ' || count(*) FROM \"Charge\"
    WHERE status::text IN ('paid','PAID','approved') AND COALESCE(\"providerFeeCents\",0) > 0"
le "SELECT '  com taxa da plataforma:    ' || count(*) FROM \"Charge\"
    WHERE status::text IN ('paid','PAID','approved') AND COALESCE(\"sigmaFeeCents\",0) > 0"

echo
echo "== faixa de valores ja cobrados =="
le "SELECT '  menor R\$ ' || round(min(\"amountCents\")/100.0,2)::text ||
           '   maior R\$ ' || round(max(\"amountCents\")/100.0,2)::text ||
           '   total R\$ ' || round(sum(\"amountCents\")/100.0,2)::text
    FROM \"Charge\" WHERE status::text IN ('paid','PAID','approved')"

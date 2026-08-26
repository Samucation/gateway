#!/usr/bin/env bash
# De quem são as cobranças, e quanto a plataforma cobra de cada aplicação?
#
# ⚠️ A taxa pode morar em DOIS lugares, e os dois precisam ser olhados:
#
#   Application.commissionBps  comissão daquela aplicação (pontos-base)
#   PrecoDoSigma               tabela de preços por escopo/provedor/método
#
# E `usoInterno` VENCE os dois: aplicação da casa pagando taxa para a casa é
# dinheiro andando em círculo, e sujaria o faturamento com receita que não
# existe. Por isso "taxa zero" pode significar coisas diferentes — sem preço
# cadastrado, ou aplicação da casa.
set -uo pipefail
NS=sigma-financeiro
DB=${POD_DB:-sigma-db-0}
le() { kubectl exec -n "$NS" "$DB" -- psql -U sigma -d sigma_financeiro -tAc "$1" 2>/dev/null | tr -d '\r'; }

echo "== aplicacoes: comissao e se sao da casa =="
le "SELECT '  ' || rpad(label, 26) || rpad(status::text, 12) ||
           'comissao ' || rpad(((\"commissionBps\"::numeric)/100)::text || '%', 9) ||
           'uso interno: ' || \"usoInterno\"::text
    FROM \"Application\" ORDER BY label"

echo
echo "== cobrancas pagas, por aplicacao =="
le "SELECT '  ' || rpad(a.label, 26) || count(*) || ' cobranca(s)   taxa da plataforma R\$ ' ||
           round(sum(c.\"sigmaFeeCents\")/100.0, 2)::text
    FROM \"Charge\" c JOIN \"Application\" a ON a.id = c.\"applicationId\"
    WHERE c.status::text IN ('paid','PAID','approved')
    GROUP BY a.label ORDER BY count(*) DESC"

echo
echo "== recebedores =="
le "SELECT '  ' || rpad(COALESCE(provider::text,'?'), 16) || count(*) || ' conta(s) conectada(s)'
    FROM \"Receiver\" GROUP BY provider"

#!/usr/bin/env bash
# O que a migracao V10 do NF-e deixou no banco, e se tem DADO dentro.
#
# ⚠️ Isto e banco FISCAL. Antes de qualquer conserto, saber se a tabela esta
# vazia ou tem carga -- apagar tabela com dado fiscal e perda que nao volta.
set -uo pipefail
P=veltrixa-nfe-postgres-0
roda() { kubectl exec -n veltrixa "$P" -- psql -U nfe -d nfe_db -tAc "$1" 2>/dev/null; }

echo "== tabelas do schema nfe, com contagem de linhas =="
roda "
SELECT t.table_name || '|' ||
       (xpath('/row/c/text()',
              query_to_xml(format('SELECT count(*) AS c FROM nfe.%I', t.table_name),
                           false, true, '')))[1]::text::bigint
FROM information_schema.tables t
WHERE t.table_schema = 'nfe'
ORDER BY t.table_name" | awk -F'|' '{printf "  %-38s %s linha(s)\n", $1, $2}'

echo
echo "== ultima migracao registrada =="
roda "SELECT 'rank ' || installed_rank || ' -> V' || version || '  ' || description || '  sucesso=' || success
      FROM nfe.flyway_schema_history ORDER BY installed_rank DESC LIMIT 3" | sed 's/^/  /'

#!/usr/bin/env bash
# O historico do Flyway do banco de NF-e.
#
# 🐞 O Pod entra em CrashLoop com `relation "fiscal_tabela_versao" already
# exists`. Isso quase sempre significa: as TABELAS estao no banco, e a tabela
# de HISTORICO do Flyway nao -- entao ele acha que precisa criar tudo de novo.
# E o tipo de estrago que uma migracao de dados por `pg_dump` seletivo deixa.
set -uo pipefail

POD=$(kubectl get pods -n veltrixa -l app=veltrixa-nfe-postgres --no-headers 2>/dev/null | awk '{print $1}' | head -1)
[ -n "$POD" ] || POD=veltrixa-nfe-postgres-0
BANCO=${1:-nfe_db}

roda() { kubectl exec -n veltrixa "$POD" -- psql -U nfe -d "$BANCO" -tAc "$1" 2>/dev/null; }

echo "== bancos =="
kubectl exec -n veltrixa "$POD" -- psql -U nfe -tAc \
  "SELECT datname FROM pg_database WHERE datistemplate = false" 2>/dev/null | sed 's/^/  /'

echo
echo "== tabelas em $BANCO =="
roda "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema')" | sed 's/^/  total: /'
roda "SELECT table_schema || '.' || table_name FROM information_schema.tables WHERE table_name LIKE '%flyway%' OR table_name = 'fiscal_tabela_versao'" | sed 's/^/  /'

echo
echo "== historico do flyway =="
h=$(roda "SELECT count(*) FROM flyway_schema_history")
if [ -n "$h" ]; then
  echo "  $h linha(s)"
  roda "SELECT installed_rank || '  ' || version || '  ' || left(description, 40) || '  sucesso=' || success FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 8" | sed 's/^/    /'
else
  echo "  ⚠️ a tabela flyway_schema_history NAO EXISTE neste banco"
  echo "     -- por isso o Flyway tenta criar do zero o que ja esta la"
fi

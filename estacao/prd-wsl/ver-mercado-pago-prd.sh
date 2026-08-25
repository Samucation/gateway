#!/usr/bin/env bash
# O Mercado Pago está habilitado para PRODUÇÃO no sigma-financeiro?
#
# ⚠️ SÓ LEITURA. Regra de ouro: este projeto se consulta, não se altera.
#
# A pergunta tem três camadas, e todas precisam bater:
#
#   1. o BANCO se declara produção (`Settings.ambiente`) — carimbado dentro dos
#      dados de propósito, para restaurar backup de produção em teste ser
#      detectável;
#   2. o Mercado Pago está em `provedoresEmProducao` — a lista existe porque uma
#      instalação de produção pode ter só UM adquirente validado;
#   3. ele não está na lista de bloqueados por divergência de taxa, que o
#      próprio serviço preenche sozinho.
set -uo pipefail
NS=sigma-financeiro
POD=${POD_DB:-sigma-db-0}

le() { kubectl exec -n "$NS" "$POD" -- psql -U sigma -d sigma_financeiro -tAc "$1" 2>/dev/null | tr -d '\r'; }

echo "== o BANCO se declara o quê? =="
le "SELECT '  ambiente: ' || ambiente FROM \"Settings\" WHERE id = 'singleton'"

echo
echo "== adquirentes autorizados a mover dinheiro REAL =="
lista=$(le "SELECT array_to_string(\"provedoresEmProducao\", ', ') FROM \"Settings\" WHERE id='singleton'")
echo "  ${lista:-(nenhum — nada em produção)}"

echo
echo "== adquirentes BLOQUEADOS pelo próprio serviço =="
col=$(le "SELECT column_name FROM information_schema.columns
          WHERE table_name='Settings' AND column_name ILIKE '%bloquead%' LIMIT 1")
if [ -n "$col" ]; then
  bl=$(le "SELECT array_to_string(\"$col\", ', ') FROM \"Settings\" WHERE id='singleton'")
  echo "  ${bl:-(nenhum)}"
else
  echo "  (coluna de bloqueio não encontrada neste esquema)"
fi

echo
echo "== o Mercado Pago tem credencial cadastrada? (sem mostrar segredo) =="
le "SELECT '  ' || t.table_name || ': ' || count(*)
    FROM information_schema.tables t
    JOIN LATERAL (SELECT 1) x ON true
    WHERE t.table_schema='public' AND t.table_name ILIKE '%credential%'
    GROUP BY t.table_name"

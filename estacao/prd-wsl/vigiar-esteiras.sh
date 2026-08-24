#!/usr/bin/env bash
# Vigia as esteiras: aprova quem chegar no portao e para quando tudo assentar.
#
# ⚠️ Em ARQUIVO, e nao inline. `$(seq ...)` dentro de
# `wsl.exe -- bash -c "..."` vira erro de sintaxe: o cifrao e o parenteses sao
# comidos pelas camadas de shell antes de chegar aqui.
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for i in $(seq 1 60); do
  bash "$AQUI/aprovar-pendentes.sh" 2>/dev/null | grep -v 'as demais'

  rodando=$(bash "$AQUI/esteira.sh" estado 2>/dev/null | grep -c 'RODANDO')
  if [ "$rodando" = "0" ]; then
    echo "  nenhuma rodando na volta $i"
    break
  fi
  sleep 40
done

echo ""
echo "== estado final =="
bash "$AQUI/esteira.sh" estado

#!/usr/bin/env bash
# Vigia as esteiras: aprova quem chegar no portao e para quando tudo assentar.
#
# ⚠️ Em ARQUIVO, e nao inline. `$(seq ...)` dentro de
# `wsl.exe -- bash -c "..."` vira erro de sintaxe: o cifrao e o parenteses sao
# comidos pelas camadas de shell antes de chegar aqui.
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 🐞 Eram 60 voltas de 40s = 40 minutos, e o vigia morria calado.
#
# Com UM executor (de propósito: build simultâneo já encheu o disco e despejou
# sete Pods), uma fila de três esteiras passa de uma hora. O vigia acabava no
# meio, ninguém aprovava o portão, e a esteira da vez ficava parada em "Input
# requested" SEGURANDO o executor — enquanto as da fila queimavam o próprio
# tempo limite e terminavam em ABORTED sem nada ter falhado.
#
# 240 voltas = até 2h40. E ele sai sozinho assim que nada mais estiver rodando,
# então o número só importa no caso ruim.
for i in $(seq 1 240); do
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

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
# 🐞 E ele saía na PRIMEIRA volta sem nada rodando.
#
# Subir o vigia logo depois de disparar as esteiras não funcionava: o Jenkins
# leva alguns segundos para tirar a build da fila, o vigia olhava antes, via
# zero e ia embora. Depois a esteira chegava ao portão, ninguém aprovava, e ela
# ficava parada SEGURANDO o único executor — com nove esperando atrás.
#
# ⚠️ E o log dele terminava com "nenhuma rodando", que se lê como "terminou tudo"
# quando na verdade era "ainda não começou nada".
#
# Agora exige QUIETAS voltas seguidas sem ninguém rodando antes de encerrar.
QUIETAS_PARA_SAIR=5
quietas=0

for i in $(seq 1 240); do
  bash "$AQUI/aprovar-pendentes.sh" 2>/dev/null | grep -v 'as demais'

  rodando=$(bash "$AQUI/esteira.sh" estado 2>/dev/null | grep -c 'RODANDO')
  if [ "$rodando" = "0" ]; then
    quietas=$((quietas + 1))
    if [ "$quietas" -ge "$QUIETAS_PARA_SAIR" ]; then
      echo "  nada rodando ha $quietas voltas seguidas (volta $i) -- encerrando"
      break
    fi
  else
    quietas=0
  fi
  sleep 40
done

echo ""
echo "== estado final =="
bash "$AQUI/esteira.sh" estado

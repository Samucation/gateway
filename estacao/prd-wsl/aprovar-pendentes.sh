#!/usr/bin/env bash
# Aprova TODA esteira parada no portao de producao.
#
# ⚠️ Existe porque o portao tem PRAZO: passados 60 minutos sem resposta, o
# Jenkins aborta a execucao -- depois de ela ter construido, testado, analisado
# e validado em homologacao. Perder tudo isso por falta de um clique e o
# desperdicio mais bobo que a esteira permite.
#
# 🐞 E varias podem estar esperando AO MESMO TEMPO sem parecer: o passo de
# aprovacao usa `agent none`, entao nao segura executor. No painel elas
# aparecem como "rodando", identicas a quem esta compilando.
set -uo pipefail

E="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/esteira.sh"

for p in live-flow sigma-financeiro sprinklegames-portal opuschat \
         cafe-mobile-erp central-ia sigma-midia gateway system-api; do
  estado=$(bash "$E" estado "$p" 2>/dev/null | head -1)
  case "$estado" in
    *PAUSED_PENDING_INPUT*)
      printf '  %-22s esperando -> ' "$p"
      bash "$E" aprovar "$p" 2>/dev/null | tail -1 | sed 's/^ *//'
      ;;
  esac
done
echo "  (as demais nao estao no portao)"

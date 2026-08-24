#!/usr/bin/env bash
# O agente do Jenkins (que roda na distro `prd`) alcança a entrada do hmg?
#
# O k3d publica o balanceador na 8090 da MÁQUINA Windows. Da distro, o caminho é
# o IP da estação na rede. Se isto não responder, religar as etapas de
# homologação só troca "não fez nada" por "falhou".
set -uo pipefail
ENTRADA=${HMG_ENTRADA:-http://192.168.15.9:8090}
echo "  entrada: $ENTRADA"
for h in urupix-hmg.cursodetecnologia.dev.br sigma-financeiro-hmg.cursodetecnologia.dev.br \
         opuschat-hmg.cursodetecnologia.dev.br central-ia-hmg.cursodetecnologia.dev.br \
         sigma-midia-hmg.cursodetecnologia.dev.br sprinklegames-hmg.cursodetecnologia.dev.br \
         veltrixa-hmg.cursodetecnologia.dev.br cafe-api-hmg.cursodetecnologia.dev.br; do
  cod=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -H "Host: $h" "$ENTRADA/" 2>/dev/null)
  printf '  %-48s %s\n' "$h" "${cod:-000}"
done

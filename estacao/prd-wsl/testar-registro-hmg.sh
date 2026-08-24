#!/usr/bin/env bash
# A distro alcança o registro de homologação (que vive no Docker)?
#
# ⚠️ Em ARQUIVO. Inline dentro de `wsl.exe -- bash -c "..."` o `$a` do laço é
# comido pelo shell do Windows e o endereço chega vazio -- a saída fica com duas
# linhas em branco e parece "não respondeu".
set -uo pipefail
for a in 192.168.15.9:32001 172.29.80.1:32001; do
  r=$(curl -s --max-time 6 "http://$a/v2/_catalog" 2>/dev/null)
  printf '  %-22s %s\n' "$a" "${r:-SEM RESPOSTA}"
done

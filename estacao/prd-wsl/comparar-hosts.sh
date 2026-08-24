#!/usr/bin/env bash
# Pergunta a MESMA rota a dois destinos e mostra código + tamanho + título.
#
#     bash comparar-hosts.sh <host> <caminho> <destino1> <destino2>
#
# ⚠️ Comparar só o código HTTP não prova nada quando os dois respondem 200 com
# conteúdo DIFERENTE — que é exatamente o risco de trocar o roteamento de um
# domínio de aplicação. Por isso vai o tamanho e o <title> junto.
set -uo pipefail
host="$1"; caminho="$2"; shift 2
for d in "$@"; do
  corpo=$(curl -s --max-time 12 -H "Host: $host" "$d$caminho" 2>/dev/null)
  cod=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -H "Host: $host" "$d$caminho" 2>/dev/null)
  titulo=$(printf '%s' "$corpo" | grep -oiE '<title[^>]*>[^<]*' | head -1 | sed 's/<[^>]*>//')
  printf '  %-42s %s  %6s bytes  %s\n' "$d" "$cod" "${#corpo}" "${titulo:0:40}"
done

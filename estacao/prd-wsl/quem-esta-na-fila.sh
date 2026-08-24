#!/usr/bin/env bash
# Quem esta CONSTRUINDO e quem esta so esperando executor.
#
# ⚠️ "RODANDO" na lista de esteiras NAO quer dizer construindo. O Jenkins daqui
# tem UM executor de proposito (build simultaneo ja encheu o disco e despejou
# sete Pods). Os demais ficam em "Waiting for next available executor" -- e o
# tempo limite da esteira corre nessa espera, entao fila comprida vira ABORTED
# sem nada ter falhado.
set -uo pipefail
J=http://127.0.0.1:8080
T=$(tr -d '\r\n' < /var/lib/jenkins/secrets/api-token)

echo "== fila do Jenkins =="
curl -s --max-time 20 -u "samuca:$T" "$J/queue/api/json" \
  | python3 -c '
import sys, json
d = json.load(sys.stdin)
itens = d.get("items", [])
if not itens:
    print("  (vazia)")
for i in itens:
    print("  %-40s %s" % (i.get("task", {}).get("fullName", "?"), i.get("why", "")[:60]))
' 2>/dev/null

echo
echo "== ultima linha do log de cada um que esta rodando =="
for p in gateway opuschat system-api cafe-mobile-erp central-ia live-flow sigma-financeiro sigma-midia sprinklegames-portal; do
  estado=$(curl -s --max-time 15 -u "samuca:$T" "$J/job/$p/job/main/lastBuild/api/json?tree=building" 2>/dev/null | grep -o 'true')
  [ "$estado" = "true" ] || continue
  linha=$(curl -s --max-time 20 -u "samuca:$T" "$J/job/$p/job/main/lastBuild/consoleText" 2>/dev/null | grep -v '^$' | tail -1 | cut -c1-84)
  printf '  %-22s %s\n' "$p" "$linha"
done

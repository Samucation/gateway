#!/usr/bin/env bash
# Por que o Jenkins reiniciou? (build "Resuming ... after Jenkins restart")
#
# ⚠️ Reinício no meio de uma build mata o `docker build` com "context canceled",
# e o estágio falha com uma mensagem que fala de BuildKit — não de Jenkins.
set -uo pipefail

echo "== o servico =="
systemctl show jenkins -p ActiveEnterTimestamp -p NRestarts -p Result 2>/dev/null | sed 's/^/  /'

echo
echo "== como ele MORREU da ultima vez =="
journalctl -u jenkins --no-pager 2>/dev/null \
  | grep -iE 'Stopping|Deactivated|Killed|signal|Main process exited|out of memory' \
  | tail -6 | cut -c1-130 | sed 's/^/  /'

echo
echo "== o nucleo matou alguem por memoria? =="
oom=$(journalctl -k --no-pager 2>/dev/null | grep -ci 'out of memory\|oom-kill')
echo "  eventos de OOM no kernel: ${oom:-0}"
journalctl -k --no-pager 2>/dev/null | grep -i 'oom-kill\|Out of memory' | tail -3 | cut -c1-130 | sed 's/^/    /'

echo
echo "== memoria agora =="
free -h 2>/dev/null | sed 's/^/  /'

echo
echo "== a distro reiniciou? =="
echo "  de pe ha: $(uptime -p 2>/dev/null)"

#!/bin/sh
# O Docker do Mac esta' respondendo? Tudo com teto de tempo -- consulta que
# pendura nao e' diagnostico, e' mais um travamento.
MAC=192.168.15.25
U=samuelferreiraduarte
CHAVE=/var/lib/jenkins/.ssh/ci-mac
SSH="sudo -u jenkins ssh -i $CHAVE -o BatchMode=yes -o ConnectTimeout=15 -o UserKnownHostsFile=/var/lib/jenkins/.ssh/known_hosts $U@$MAC"
D=/Users/samuelferreiraduarte/.orbstack/bin/docker

echo "== carga do Mac =="
$SSH 'uptime' | sed 's/^/  /'

echo
echo "== OrbStack vivo? =="
$SSH 'pgrep -fl OrbStack 2>/dev/null | head -2 | cut -c1-90' | sed 's/^/  /'

echo
echo "== docker ps (teto 20s) =="
$SSH "timeout 20 $D ps -a --format '{{.Names}} | {{.Status}} | {{.Image}}' 2>&1 | head -6; echo \"  saida=\$?\"" | sed 's/^/  /'

echo
echo "== docker info resumido (teto 20s) =="
$SSH "timeout 20 $D info --format 'containers={{.Containers}} rodando={{.ContainersRunning}} imagens={{.Images}}' 2>&1 | head -3; echo \"  saida=\$?\"" | sed 's/^/  /'

echo
echo "== processos docker/qemu pesados =="
$SSH "ps -Ao pcpu,rss,comm 2>/dev/null | sort -rn | head -6" | sed 's/^/  /'

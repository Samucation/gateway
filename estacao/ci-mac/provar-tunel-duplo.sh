#!/bin/sh
# Prova que o Mac alcanca AS DUAS portas pelo tunel: registro e gateway.
MAC=192.168.15.25
U=samuelferreiraduarte
CHAVE=/var/lib/jenkins/.ssh/ci-mac
SSH="sudo -u jenkins ssh -i $CHAVE -o BatchMode=yes -o ConnectTimeout=20 -o UserKnownHostsFile=/var/lib/jenkins/.ssh/known_hosts $U@$MAC"

echo "== estado do servico =="
systemctl is-active tunel-registro | sed 's/^/  /'

echo
echo "== do lado do Mac =="
$SSH 'curl -s -o /dev/null -m 12 -w "  registro  localhost:32000      -> %{http_code}\n" http://localhost:32000/v2/
      curl -s -o /dev/null -m 12 -H "Host: sonar.hmg" -w "  sonar     127.0.0.1:8050       -> %{http_code}\n" http://127.0.0.1:8050/api/server/version
      echo "  versao do sonar vista do Mac:"
      curl -s -m 12 -H "Host: sonar.hmg" http://127.0.0.1:8050/api/server/version | head -c 40
      echo'

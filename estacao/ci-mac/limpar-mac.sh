#!/bin/sh
# Limpa conteineres e cache no agente Mac.
#
# ⚠️ O `post { always }` da esteira NAO consegue limpar quando a build termina
# sem contexto de no' (com `agent none` no topo isso acontece). Entao sobram
# Postgres de teste no Mac -- e eles seguram memoria ate' alguem varrer.
MAC=192.168.15.25
U=samuelferreiraduarte
CHAVE=/var/lib/jenkins/.ssh/ci-mac
SSH="sudo -u jenkins ssh -i $CHAVE -o BatchMode=yes -o ConnectTimeout=20 -o UserKnownHostsFile=/var/lib/jenkins/.ssh/known_hosts $U@$MAC"

$SSH 'D=$HOME/.orbstack/bin/docker
  echo "  antes: $($D ps -aq | wc -l | tr -d " ") conteiner(es)"
  for c in $($D ps -aq); do $D rm -f "$c" >/dev/null 2>&1; done
  echo "  depois: $($D ps -aq | wc -l | tr -d " ") conteiner(es)"
  $D system prune -f 2>&1 | tail -2 | sed "s/^/  /"
  echo "  disco livre no Mac:"
  df -h / | tail -1 | sed "s/^/    /"'

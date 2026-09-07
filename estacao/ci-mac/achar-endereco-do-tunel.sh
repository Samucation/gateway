#!/bin/sh
# ===========================================================================
# 🐞 `--network host` NO macOS NAO E' A REDE DO MAC
# ===========================================================================
# O Docker do Mac roda dentro de uma VM Linux. `--network host` compartilha a
# rede DESSA VM -- entao `127.0.0.1` dentro do conteiner e' o loopback da VM,
# e nao o do macOS.
#
# O tunel SSH escuta no `127.0.0.1` do macOS. Por isso o scanner, mesmo com
# `--add-host sonar.hmg:127.0.0.1`, nao alcanca nada.
#
# ⚠️ E o teste que fiz antes ("conteiner alcanca conteiner por localhost com
# --net host: ALCANCA") NAO contradiz isso: os dois conteineres estavam na
# mesma VM. Eu medi comunicacao dentro da VM e concluí sobre o Mac.
#
# Aqui procuro qual endereco, de DENTRO do conteiner, chega ao tunel.
MAC=192.168.15.25
U=samuelferreiraduarte
CHAVE=/var/lib/jenkins/.ssh/ci-mac
SSH="sudo -u jenkins ssh -i $CHAVE -o BatchMode=yes -o ConnectTimeout=20 -o UserKnownHostsFile=/var/lib/jenkins/.ssh/known_hosts $U@$MAC"
D=/Users/samuelferreiraduarte/.orbstack/bin/docker
G=/opt/homebrew/bin/gtimeout

echo "== do MAC (fora de conteiner) o tunel responde? =="
$SSH 'curl -s -o /dev/null -m 10 -H "Host: sonar.hmg" -w "  127.0.0.1:8050 -> %{http_code}\n" http://127.0.0.1:8050/api/server/version'

echo
echo "== de DENTRO de um conteiner, testando varios enderecos =="
$SSH "$G 120 $D run --rm --network host alpine:3 sh -c '
  apk add --no-cache curl >/dev/null 2>&1
  for alvo in 127.0.0.1 host.docker.internal host.orb.internal 192.168.15.25; do
    cod=\$(curl -s -o /dev/null -m 6 -H \"Host: sonar.hmg\" -w \"%{http_code}\" http://\$alvo:8050/api/server/version 2>/dev/null)
    echo \"    \$alvo -> \$cod\"
  done'" 2>&1 | sed 's/^/  /'

echo
echo "== e o registro, pelos mesmos enderecos =="
$SSH "$G 120 $D run --rm --network host alpine:3 sh -c '
  apk add --no-cache curl >/dev/null 2>&1
  for alvo in 127.0.0.1 host.docker.internal host.orb.internal; do
    cod=\$(curl -s -o /dev/null -m 6 -w \"%{http_code}\" http://\$alvo:32000/v2/ 2>/dev/null)
    echo \"    \$alvo -> \$cod\"
  done'" 2>&1 | sed 's/^/  /'

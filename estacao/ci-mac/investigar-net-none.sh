#!/bin/sh
# Por que `--net none` pendurou o daemon do OrbStack?
#
# ⚠️ Testar isso SEM teto de tempo enrosca o daemon de novo. macOS nao tem
# `timeout` (e' do GNU coreutils), entao instalo `coreutils` -- que da'
# `gtimeout` -- antes de qualquer coisa. Formula, nao cask: sem senha.
MAC=192.168.15.25
U=samuelferreiraduarte
CHAVE=/var/lib/jenkins/.ssh/ci-mac
SSH="sudo -u jenkins ssh -i $CHAVE -o BatchMode=yes -o ConnectTimeout=20 -o UserKnownHostsFile=/var/lib/jenkins/.ssh/known_hosts $U@$MAC"
D=/Users/samuelferreiraduarte/.orbstack/bin/docker

echo "== gtimeout disponivel? =="
TEM=$($SSH 'command -v /opt/homebrew/bin/gtimeout || echo NAO')
echo "  $TEM"
if [ "$TEM" = "NAO" ]; then
  echo "  instalando coreutils (formula, sem senha)..."
  $SSH 'export PATH=/opt/homebrew/bin:$PATH; export HOMEBREW_NO_AUTO_UPDATE=1; brew install coreutils 2>&1 | tail -3'
fi
G=/opt/homebrew/bin/gtimeout

echo
echo "== controle: SEM --net none =="
$SSH "$G 45 $D run --rm alpine:3 echo OK-SEM-NET-NONE 2>&1 | tail -2; echo \"  saida=\$?\"" 2>&1 | sed 's/^/  /'

echo
echo "== o suspeito: COM --net none =="
$SSH "$G 45 $D run --rm --net none alpine:3 echo OK-COM-NET-NONE 2>&1 | tail -2; echo \"  saida=\$? (124 = pendurou)\"" 2>&1 | sed 's/^/  /'

echo
echo "== alternativa: --network none (nome longo) =="
$SSH "$G 45 $D run --rm --network none alpine:3 echo OK-NETWORK-NONE 2>&1 | tail -2; echo \"  saida=\$?\"" 2>&1 | sed 's/^/  /'

echo
echo "== com volume montado, que e' o caso real =="
$SSH "T=\$(mktemp -d); $G 45 $D run --rm --network none -v \$T:/w -w /w alpine:3 sh -c 'echo OK-COM-VOLUME; ls /w' 2>&1 | tail -3; echo \"  saida=\$?\"; rm -rf \$T" 2>&1 | sed 's/^/  /'

echo
echo "== o daemon sobreviveu? =="
$SSH "$G 20 $D ps -a --format '{{.Names}} {{.Status}}' 2>&1 | head -3; echo \"  saida=\$?\"" 2>&1 | sed 's/^/  /'

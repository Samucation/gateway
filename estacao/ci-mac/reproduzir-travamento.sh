#!/bin/sh
# Reproduz, no Mac, o comando exato em que a build #2 travou por 39 minutos:
#
#   docker run --rm --net none -v <workspace>:/w -w /w alpine:3 sh -c 'rm -rf ...'
#
# ⚠️ `--net none` foi escolhido na estacao porque aquele conteiner APAGA
# ARQUIVO e nao precisa de rede. Mas ali o `docker` e' nerdctl sobre
# containerd; aqui e' Docker de verdade, noutro sistema operacional. Mesma
# linha, mundo diferente.
MAC=192.168.15.25
U=samuelferreiraduarte
CHAVE=/var/lib/jenkins/.ssh/ci-mac
SSH="sudo -u jenkins ssh -i $CHAVE -o BatchMode=yes -o ConnectTimeout=20 -o UserKnownHostsFile=/var/lib/jenkins/.ssh/known_hosts $U@$MAC"
P='export PATH=$HOME/.orbstack/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'

echo "== a imagem alpine:3 arm64 esta local? =="
$SSH "$P; docker image inspect alpine:3 --format '  {{.Id}} {{.Architecture}}' 2>/dev/null || echo '  NAO esta local'"

echo
echo "== com --net none, teto de 60s =="
$SSH "$P
  T=\$(mktemp -d)
  timeout 60 docker run --rm --net none -v \$T:/w -w /w alpine:3 sh -c 'echo dentro; ls -la /w' 2>&1 | tail -5 | sed 's/^/  /'
  echo \"  saida=\$?  (124 = travou ate o teto)\"
  rm -rf \$T"

echo
echo "== SEM --net none (controle), teto de 60s =="
$SSH "$P
  T=\$(mktemp -d)
  timeout 60 docker run --rm -v \$T:/w -w /w alpine:3 sh -c 'echo dentro; ls -la /w' 2>&1 | tail -5 | sed 's/^/  /'
  echo \"  saida=\$?\"
  rm -rf \$T"

echo
echo "== o que esta rodando no Docker do Mac agora =="
$SSH "$P; docker ps --format '  {{.Names}}  {{.Status}}  {{.Command}}' 2>/dev/null | head -6"

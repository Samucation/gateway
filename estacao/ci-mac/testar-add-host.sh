#!/bin/sh
# A combinacao EXATA do scanner: --network host + --add-host + nome sonar.hmg.
#
# ⚠️ Ja errei duas hipoteses aqui. `127.0.0.1` de dentro do conteiner
# ALCANCA o tunel (testado: 200). Entao o problema nao e' "a rede do
# conteiner nao ve o Mac" -- e' outra coisa, e o jeito de achar e' reproduzir
# a linha exata, mudando UMA variavel por vez.
MAC=192.168.15.25
U=samuelferreiraduarte
CHAVE=/var/lib/jenkins/.ssh/ci-mac
SSH="sudo -u jenkins ssh -i $CHAVE -o BatchMode=yes -o ConnectTimeout=20 -o UserKnownHostsFile=/var/lib/jenkins/.ssh/known_hosts $U@$MAC"
D=/Users/samuelferreiraduarte/.orbstack/bin/docker
G=/opt/homebrew/bin/gtimeout

echo "== 1. arm64 + --add-host + nome =="
$SSH "$G 120 $D run --rm --network host --add-host sonar.hmg:127.0.0.1 alpine:3 sh -c '
  apk add --no-cache curl >/dev/null 2>&1
  echo \"    /etc/hosts: \$(grep sonar /etc/hosts || echo AUSENTE)\"
  echo \"    codigo: \$(curl -s -o /dev/null -m 8 -w %{http_code} http://sonar.hmg:8050/api/server/version)\"'" 2>&1 | sed 's/^/  /'

echo
echo "== 2. amd64 EMULADO (como o scanner) + --add-host + nome =="
$SSH "$G 180 $D run --rm --platform linux/amd64 --network host --add-host sonar.hmg:127.0.0.1 alpine:3 sh -c '
  apk add --no-cache curl >/dev/null 2>&1
  echo \"    arquitetura: \$(uname -m)\"
  echo \"    /etc/hosts: \$(grep sonar /etc/hosts || echo AUSENTE)\"
  echo \"    codigo: \$(curl -s -o /dev/null -m 8 -w %{http_code} http://sonar.hmg:8050/api/server/version)\"'" 2>&1 | sed 's/^/  /'

echo
echo "== 3. a propria imagem do scanner, so' testando rede =="
$SSH "$G 240 $D run --rm --network host --add-host sonar.hmg:127.0.0.1 \
  --entrypoint sh sonarsource/sonar-scanner-cli:latest -c '
  echo \"    arquitetura: \$(uname -m)\"
  echo \"    /etc/hosts: \$(grep sonar /etc/hosts || echo AUSENTE)\"
  echo \"    codigo: \$(curl -s -o /dev/null -m 8 -w %{http_code} http://sonar.hmg:8050/api/server/version 2>/dev/null || echo sem-curl)\"'" 2>&1 | sed 's/^/  /'

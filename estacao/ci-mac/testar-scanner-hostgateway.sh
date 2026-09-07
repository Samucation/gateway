#!/bin/sh
# O scanner conecta se `sonar.hmg` apontar para o HOST em vez de 127.0.0.1?
#
# ⚠️ `curl` (conexao bloqueante) alcanca 127.0.0.1:8050 com 200 de dentro do
# conteiner. O Java falha em `connectAsync` (nao bloqueante) no MESMO
# endereco. Se apontar para o endereco do host resolver, o problema esta' no
# repasse de loopback do OrbStack, e nao na emulacao.
MAC=192.168.15.25
U=samuelferreiraduarte
CHAVE=/var/lib/jenkins/.ssh/ci-mac
SSH="sudo -u jenkins ssh -i $CHAVE -o BatchMode=yes -o ConnectTimeout=20 -o UserKnownHostsFile=/var/lib/jenkins/.ssh/known_hosts $U@$MAC"
D=/Users/samuelferreiraduarte/.orbstack/bin/docker
G=/opt/homebrew/bin/gtimeout

echo "== que IP e' host.docker.internal la dentro? =="
$SSH "$G 60 $D run --rm --network host alpine:3 sh -c 'getent hosts host.docker.internal || echo ausente'" 2>&1 | sed 's/^/  /'

echo
echo "== A) sonar.hmg -> host-gateway =="
$SSH "T=\$(mktemp -d); echo 'x = 1' > \$T/a.py
  $G 240 $D run --rm --network host \
    --add-host sonar.hmg:host-gateway \
    -v \$T:/usr/src \
    -e SONAR_HOST_URL=http://sonar.hmg:8050 -e SONAR_TOKEN=falso \
    sonarsource/sonar-scanner-cli:latest \
    -Dsonar.projectKey=zz -Dsonar.sources=. 2>&1 \
    | grep -iE 'failed to query|EXECUTION|not authorized|401|Unauthorized|server version|ERROR' | head -5
  rm -rf \$T" 2>&1 | sed 's/^/  /'

echo
echo "== B) SEM --network host, usando host.docker.internal direto =="
$SSH "T=\$(mktemp -d); echo 'x = 1' > \$T/a.py
  $G 240 $D run --rm \
    -v \$T:/usr/src \
    -e SONAR_HOST_URL=http://host.docker.internal:8050 -e SONAR_TOKEN=falso \
    sonarsource/sonar-scanner-cli:latest \
    -Dsonar.projectKey=zz -Dsonar.sources=. 2>&1 \
    | grep -iE 'failed to query|EXECUTION|not authorized|401|Unauthorized|server version|ERROR' | head -5
  rm -rf \$T" 2>&1 | sed 's/^/  /'

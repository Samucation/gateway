#!/bin/sh
# Roda o scanner do Sonar A MAO, com depuracao, para ver a excecao real.
#
# ⚠️ `curl` da MESMA imagem alcanca `sonar.hmg:8050` com 200. O scanner, que
# e' Java, falha com "failed: null" -- mensagem sem conteudo. Entao a
# diferenca esta' no cliente HTTP, e nao na rede.
#
# `-Dsonar.verbose=true` faz ele imprimir a pilha em vez do `null`.
MAC=192.168.15.25
U=samuelferreiraduarte
CHAVE=/var/lib/jenkins/.ssh/ci-mac
SSH="sudo -u jenkins ssh -i $CHAVE -o BatchMode=yes -o ConnectTimeout=20 -o UserKnownHostsFile=/var/lib/jenkins/.ssh/known_hosts $U@$MAC"
D=/Users/samuelferreiraduarte/.orbstack/bin/docker
G=/opt/homebrew/bin/gtimeout

echo "== scanner com verbose, so' ate' a consulta de versao =="
$SSH "T=\$(mktemp -d); echo 'print(1)' > \$T/a.py
  $G 300 $D run --rm --network host \
    --add-host sonar.hmg:127.0.0.1 \
    -v \$T:/usr/src \
    -e SONAR_HOST_URL=http://sonar.hmg:8050 \
    -e SONAR_TOKEN=token-falso \
    sonarsource/sonar-scanner-cli:latest \
    -Dsonar.projectKey=zz-teste -Dsonar.sources=. -Dsonar.verbose=true 2>&1 | head -40
  rm -rf \$T" 2>&1 | sed 's/^/  /'

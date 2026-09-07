#!/bin/sh
# HIPOTESE: o scanner falha porque roda EMULADO.
#
# O log dele mostra `uname -m returned 'x86_64'` num Mac arm64, e a falha e'
# `java.net.ConnectException: null` em `PlainHttpConnection.connectAsync` --
# conexao NAO BLOQUEANTE, que e' o tipo de syscall que mais sofre sob QEMU.
#
# `curl` da MESMA imagem alcanca o mesmo endereco com 200, o que descarta
# rede e reforca que o problema e' a emulacao.
#
# ⚠️ Isto reforca a regra ja' aprendida hoje: conteiner FERRAMENTA roda
# NATIVO no agente. So' a imagem final da aplicacao precisa casar com o
# cluster.
MAC=192.168.15.25
U=samuelferreiraduarte
CHAVE=/var/lib/jenkins/.ssh/ci-mac
SSH="sudo -u jenkins ssh -i $CHAVE -o BatchMode=yes -o ConnectTimeout=20 -o UserKnownHostsFile=/var/lib/jenkins/.ssh/known_hosts $U@$MAC"
D=/Users/samuelferreiraduarte/.orbstack/bin/docker
G=/opt/homebrew/bin/gtimeout

echo "== a imagem do scanner tem variante arm64? =="
$SSH "$G 120 $D manifest inspect sonarsource/sonar-scanner-cli:latest 2>/dev/null | grep -A2 'architecture' | grep -oE '\"(amd64|arm64)\"' | sort -u" 2>&1 | sed 's/^/  /'

echo
echo "== puxando arm64 =="
$SSH "$G 300 $D pull --platform linux/arm64 sonarsource/sonar-scanner-cli:latest 2>&1 | tail -2" | sed 's/^/  /'
$SSH "$G 30 $D image inspect sonarsource/sonar-scanner-cli:latest --format '  arquitetura agora: {{.Architecture}}'" 2>&1 | sed 's/^/  /'

echo
echo "== o scanner NATIVO consegue falar com o Sonar? =="
$SSH "T=\$(mktemp -d); echo 'x = 1' > \$T/a.py
  $G 300 $D run --rm --platform linux/arm64 --network host \
    --add-host sonar.hmg:127.0.0.1 \
    -v \$T:/usr/src \
    -e SONAR_HOST_URL=http://sonar.hmg:8050 \
    -e SONAR_TOKEN=token-falso \
    sonarsource/sonar-scanner-cli:latest \
    -Dsonar.projectKey=zz-teste -Dsonar.sources=. 2>&1 | grep -E 'uname|INFO  Linux|Failed to query|EXECUTION|not authorized|Unauthorized|401|server version' | head -8
  rm -rf \$T" 2>&1 | sed 's/^/  /'

#!/usr/bin/env bash
# Cria o Secret do SonarQube e reinicia os Pods dele.
#
# ⚠️ Em ARQUIVO, e nao inline. Passar isto por
# `wsl.exe -- bash -c "..."` faz as variaveis serem comidas pelas camadas de
# shell: `$COFRE` chegava VAZIO e o `mkdir` reclamava de diretorio ''.
set -euo pipefail

COFRE=/var/lib/prd-segredos
mkdir -p "$COFRE"
chmod 700 "$COFRE"
ARQ="$COFRE/sonarqube.env"

# ⚠️ Senha ESTAVEL: sortear de novo a cada execucao trocaria a senha embaixo
# de um Postgres que ja tem o banco do Sonar dentro, e ele pararia de conectar
# sem nada ter mudado.
if [ -f "$ARQ" ] && grep -q '^POSTGRES_PASSWORD=' "$ARQ"; then
  senha=$(grep -m1 '^POSTGRES_PASSWORD=' "$ARQ" | cut -d= -f2-)
else
  # 🐞 `set -o pipefail` + `head -c` MATAM ESTE SCRIPT EM SILENCIO.
  #
  # `head -c 24` fecha a entrada assim que tem 24 bytes; o `tr`, ainda lendo
  # de `/dev/urandom`, leva SIGPIPE e sai diferente de zero. Com `pipefail` o
  # cano inteiro e considerado falho e o `set -e` encerra o script -- DEPOIS
  # de gerar a senha e ANTES de aplicar o Secret.
  #
  # O sintoma foi mudo: o script "rodava", nao imprimia nada, e os Pods
  # seguiam em `CreateContainerConfigError` como se nada tivesse acontecido.
  senha=$( { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom || true; } | head -c 24)
  printf 'POSTGRES_PASSWORD=%s\n' "$senha" >> "$ARQ"
  chmod 600 "$ARQ"
fi

# Pela ENTRADA, nunca por argumento: em `ps` a senha ficaria visivel.
printf 'apiVersion: v1
kind: Secret
metadata:
  name: sonarqube-secrets
  namespace: sonarqube
type: Opaque
stringData:
  POSTGRES_PASSWORD: |-
    %s
' "$senha" | kubectl apply -f - | tail -1

kubectl delete pod --all -n sonarqube --force --grace-period=0 >/dev/null 2>&1 || true
echo "  esperando o sonar subir (ele demora: indexa na primeira partida)..."
for i in $(seq 1 40); do
  pronto=$(kubectl get pods -n sonarqube --no-headers 2>/dev/null | grep -c '1/1')
  if [ "$pronto" -ge 2 ]; then echo "  os dois Pods de pe"; break; fi
  sleep 15
done
kubectl get pods -n sonarqube --no-headers 2>/dev/null

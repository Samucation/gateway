#!/usr/bin/env bash
# Lista os ESTAGIOS do ultimo build e mostra onde ele parou.
#
#     bash estagios-do-build.sh <projeto> [linhas-do-erro]
#
# ⚠️ Em ARQUIVO, e nao inline: `$(...)` dentro de `wsl.exe -- bash -c "..."`
# chega mastigado e vira erro de sintaxe. Mesma razao do `esteira.sh`.
#
# Existe porque `esteira.sh log` mostra so o RABO do console (40 linhas), e o
# rabo de um pipeline que falha no meio e a saida do estagio SEGUINTE -- que
# costuma estar bem, e manda a investigacao para o lado errado.
set -uo pipefail

J=http://127.0.0.1:8080
U=samuca
T=$(tr -d '\r\n' < /var/lib/jenkins/secrets/api-token 2>/dev/null)
[ -z "$T" ] && { echo "  ⚠️ sem token em /var/lib/jenkins/secrets/api-token"; exit 3; }

PROJ=${1:?informe o projeto}
N=${2:-40}

CONSOLE=$(curl -s --max-time 90 -u "$U:$T" \
  "$J/job/$PROJ/job/main/lastBuild/consoleText" 2>/dev/null)

if [ -z "$CONSOLE" ]; then
  echo "  ⚠️ console vazio — projeto errado, ou o build ainda nao comecou"
  exit 2
fi

echo "== ESTAGIOS =="
# O Jenkins marca cada estagio com `[Pipeline] { (Nome)`. O que vem depois do
# ULTIMO e onde ele estava quando parou.
echo "$CONSOLE" | grep -E '^\[Pipeline\] \{ \(' | sed 's/^\[Pipeline\] { (/  • /; s/)$//'

echo
echo "== ONDE PAROU =="
ULTIMO=$(echo "$CONSOLE" | grep -E '^\[Pipeline\] \{ \(' | tail -1 | sed 's/^\[Pipeline\] { (//; s/)$//')
echo "  ultimo estagio aberto: ${ULTIMO:-?}"

echo
echo "== O ERRO =="
# Procura o primeiro sinal de falha real e mostra o contexto ANTES dele: a
# causa costuma estar acima da linha que anuncia o fracasso.
echo "$CONSOLE" \
  | grep -nE 'ERROR: script returned|^ERROR:|hudson\.AbortException|FAILURE|❌|Error:|error:' \
  | head -5

echo
echo "  --- contexto das ultimas $N linhas uteis ---"
echo "$CONSOLE" | grep -vE '^\[Pipeline\]' | tail -"$N" | cut -c1-160 | sed 's/^/    /'

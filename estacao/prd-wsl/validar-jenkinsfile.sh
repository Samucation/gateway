#!/usr/bin/env bash
# Valida a SINTAXE de um Jenkinsfile no proprio Jenkins, sem rodar build.
#
#     bash validar-jenkinsfile.sh /caminho/para/Jenkinsfile
#
# ⚠️ Existe porque erro de Groovy no Jenkinsfile so aparece DEPOIS de o build
# comecar -- e ai ele ja gastou clone, npm ci e alguns minutos de fila para
# morrer numa chave mal fechada. O `pipeline-model-converter` responde em
# segundos.
#
# ⚠️ O que ele NAO pega: o sandbox. Uma chamada que a lista de permissoes
# recusa (`RejectedAccessException`) passa aqui e falha no build -- ja
# aconteceu neste projeto com `r['quem']`. Sintaxe valida nao e execucao
# permitida.
set -uo pipefail

J=http://127.0.0.1:8080
U=samuca
T=$(tr -d '\r\n' < /var/lib/jenkins/secrets/api-token 2>/dev/null)
[ -z "$T" ] && { echo "  ⚠️ sem token em /var/lib/jenkins/secrets/api-token"; exit 3; }

ARQ=${1:?informe o caminho do Jenkinsfile}
[ -f "$ARQ" ] || { echo "  ⚠️ nao achei $ARQ"; exit 2; }

CRUMB=$(curl -s --max-time 20 -u "$U:$T" \
  "$J/crumbIssuer/api/json" 2>/dev/null \
  | sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p')

RESP=$(curl -s --max-time 60 -u "$U:$T" \
  ${CRUMB:+-H "Jenkins-Crumb: $CRUMB"} \
  -F "jenkinsfile=<$ARQ" \
  "$J/pipeline-model-converter/validate" 2>/dev/null)

echo "$RESP"

# A resposta de sucesso e exatamente esta frase; qualquer outra coisa e erro.
echo "$RESP" | grep -q "successfully validated" || exit 1

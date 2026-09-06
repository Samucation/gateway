#!/bin/sh
# Valida um Jenkinsfile no linter DECLARATIVO do proprio Jenkins.
#
#     sh validar-jenkinsfile.sh /caminho/para/Jenkinsfile
#
# ⚠️ Isto NAO e' `groovy -c`. O linter do Jenkins conhece a gramatica
# declarativa (agent/stages/post/parameters) e pega erro que um parser Groovy
# generico deixa passar -- por exemplo `agent` em lugar invalido ou `stages`
# aninhado errado.
#
# ⚠️ E e' MUITO mais barato que descobrir pela build: um erro de estrutura so'
# aparece depois de a build entrar na fila, pegar o executor e falhar -- e
# nesta casa a fila e' de um executor so'.
ARQ="${1:?uso: validar-jenkinsfile.sh <caminho do Jenkinsfile>}"
[ -f "$ARQ" ] || { echo "nao achei $ARQ"; exit 2; }

T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" \
        | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

echo "== validando $ARQ =="
SAIDA=$(curl -s -m 60 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
        -F "jenkinsfile=<$ARQ" "$J/pipeline-model-converter/validate")
rm -f "$CK"

echo "$SAIDA" | sed 's/^/  /'
echo
case "$SAIDA" in
  *"successfully validated"*) echo "  VERDE"; exit 0 ;;
  *) echo "  VERMELHO -- corrija antes de rodar"; exit 1 ;;
esac

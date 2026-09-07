#!/bin/sh
# Primeiro disparo de um job novo -- SEM parametros, so' para o Jenkins
# registra-los.
#
# 🐞 `buildWithParameters` devolve HTTP 400 enquanto o job nunca rodou. Quem
# trata esse 400 caindo para o disparo simples acaba rodando com o PADRAO e
# achando que rodou com o parametro pedido -- foi o que me enganou uma vez.
# Aqui o disparo simples e' INTENCIONAL e explicito.
JOB="${1:?uso: primeiro-disparo.sh <job>}"
T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)
curl -s -m 60 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  -X POST "$J/job/$JOB/build" -o /dev/null \
  -w "  disparo simples: HTTP %{http_code}  (registra os parametros)\n"
rm -f "$CK"

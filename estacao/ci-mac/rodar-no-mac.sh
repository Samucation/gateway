#!/bin/sh
# Faz o Jenkins descobrir o branch e dispara a build nele.
#
#   sh rodar-no-mac.sh <job-multibranch> <branch> [label-do-agente]
#
# ⚠️ Num branch != main os estagios de deploy sao PULADOS sozinhos (eles tem
# `when { branch 'main' }`). Por isso da' para exercitar o CI inteiro sem
# nenhum risco de implantar no site do cliente.
set -e
JOB="${1:?uso: rodar-no-mac.sh <job> <branch> [label]}"
BR="${2:?uso: rodar-no-mac.sh <job> <branch> [label]}"
LABEL="${3:-mac-arm}"

T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" \
        | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

echo "== varrendo o repositorio para achar o branch =="
curl -s -m 120 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  -X POST "$J/job/$JOB/build?delay=0" -o /dev/null -w '  scan: HTTP %{http_code}\n'

echo "  esperando o branch aparecer..."
i=0
while [ $i -lt 24 ]; do
  C=$(curl -s -m 20 -u "samuca:$T" -o /dev/null -w '%{http_code}' "$J/job/$JOB/job/$BR/api/json")
  [ "$C" = "200" ] && { echo "  branch '$BR' encontrado"; break; }
  sleep 5; i=$((i+1))
done
[ "$C" = "200" ] || { echo "  branch nao apareceu"; rm -f "$CK"; exit 1; }

echo
echo "== disparando com AGENTE_CI='$LABEL' =="
curl -s -m 60 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  -X POST "$J/job/$JOB/job/$BR/buildWithParameters" \
  --data-urlencode "AGENTE_CI=$LABEL" \
  -o /dev/null -w '  disparo: HTTP %{http_code}\n'

rm -f "$CK"
echo
echo "  acompanhe com: sh acompanhar-build.sh $JOB $BR"

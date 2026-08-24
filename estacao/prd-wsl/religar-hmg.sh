#!/usr/bin/env bash
# Instala e roda o script que religa as etapas de homologação das esteiras.
#
# ⚠️ SEM reiniciar o Jenkins: `init.groovy.d` só roda na partida, e reiniciar
# com esteira em andamento aborta o que estiver rodando. O script é copiado para
# lá (para valer nas próximas partidas) E executado agora pelo console.
set -uo pipefail

J=http://127.0.0.1:8080
U=samuca
T=$(tr -d '\r\n' < /var/lib/jenkins/secrets/api-token 2>/dev/null)
ORIGEM=/mnt/e/Desenvolvimento/Dev/Workspace/gateway/vm/hmg-religado.groovy
DESTINO=/var/lib/jenkins/init.groovy.d/30-hmg-religado.groovy

[ -f "$ORIGEM" ] || { echo "  ❌ nao achei $ORIGEM"; exit 1; }

install -o jenkins -g jenkins -m 644 "$ORIGEM" "$DESTINO"
echo "  copiado para $DESTINO (vale nas proximas partidas)"

CR=$(curl -s --max-time 20 -u "$U:$T" "$J/crumbIssuer/api/json" \
     | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"]+":"+d["crumb"])')

echo "  rodando agora pelo console:"
curl -s --max-time 60 -u "$U:$T" -H "$CR" \
  --data-urlencode "script=$(cat "$ORIGEM")" \
  "$J/scriptText" | sed 's/^/    /'

echo
echo "  == variaveis globais do Jenkins agora =="
curl -s --max-time 30 -u "$U:$T" -H "$CR" --data-urlencode 'script=
import jenkins.model.Jenkins
import hudson.slaves.EnvironmentVariablesNodeProperty
def p = Jenkins.get().getGlobalNodeProperties().get(EnvironmentVariablesNodeProperty)
if (p == null) { println "    (nenhuma)" }
else p.getEnvVars().each { k, v -> println "    ${k} = ${v}" }
' "$J/scriptText" | sed 's/^/  /'

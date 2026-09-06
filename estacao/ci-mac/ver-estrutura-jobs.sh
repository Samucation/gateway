#!/bin/sh
# Estrutura real dos jobs (pastas, multibranch, branches).
#
# ⚠️ O caminho da API nao e' `/job/<nome>/job/<branch>` quando ha' PASTA DE
# ORGANIZACAO no meio -- vira `/job/<org>/job/<repo>/job/<branch>`. Chutar o
# caminho devolve 404 que se le' como "o branch nao existe".
T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

cat > /tmp/e.groovy <<'GROOVY'
import jenkins.model.Jenkins
def s = new StringBuilder()
Jenkins.instance.getAllItems().each { it ->
    s << "  " + it.class.simpleName.padRight(26) + it.fullName + "\n"
}
println s.toString()
null
GROOVY

curl -s -m 60 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/e.groovy" "$J/scriptText" 2>&1 | head -40
rm -f "$CK" /tmp/e.groovy

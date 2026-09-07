#!/bin/sh
# Remove os jobs descartaveis criados durante a migracao.
#
# ⚠️ Eles apontam para branches `ci-no-mac`/`teste-ci-mac`. Deixados para tras,
# alguem os dispara meses depois achando que sao a esteira de verdade.
T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

cat > /tmp/lj.groovy <<'GROOVY'
import jenkins.model.Jenkins
def s = new StringBuilder()
['zz-cartorio-mac', 'zz-sigma-payments-mac', 'zz-fumaca-mac', 'zz-prova-agent-any'].each { n ->
    def j = Jenkins.instance.getItemByFullName(n)
    if (j) { j.delete(); s << "  removido: " + n + "\n" }
}
if (s.length() == 0) { s << "  nada a remover\n" }
println s.toString()
null
GROOVY

curl -s -m 60 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/lj.groovy" "$J/scriptText" 2>&1 | head -8
rm -f "$CK" /tmp/lj.groovy

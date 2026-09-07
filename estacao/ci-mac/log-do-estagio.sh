#!/bin/sh
# Log de UM estagio especifico -- do "{ (Nome)" ate' o proximo estagio.
#
# ⚠️ Filtrar o log inteiro por "error" nao serve: saida de teste tem
# "Errors: 0" em toda linha, e isso afoga a falha de verdade.
JOB="${1:?uso: log-do-estagio.sh <job> <trecho-do-nome>}"
EST="${2:?}"
T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

cat > /tmp/le.groovy <<GROOVY
import jenkins.model.Jenkins
def b = Jenkins.instance.getItemByFullName('$JOB')?.getLastBuild()
def s = new StringBuilder()
def l = b.getLog(6000)
def dentro = false
l.each { x ->
  if (x =~ /\\[Pipeline\\] \\{ \\(/) {
    dentro = (x.contains('$EST'))
  }
  if (dentro) s << "  " + x.take(150) + "\n"
}
println s.toString()
null
GROOVY

curl -s -m 90 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/le.groovy" "$J/scriptText" 2>&1 | tail -40
rm -f "$CK" /tmp/le.groovy

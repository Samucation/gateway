#!/bin/sh
# Quais estagios EXECUTARAM e quais foram PULADOS -- com o motivo.
#
# ⚠️ "SUCCESS" nao diz o que rodou. Um pipeline cujos estagios pesados foram
# pulados por `when` fecha verde e em pouco tempo -- e comparar esse tempo
# com outro que rodou tudo e' comparar coisas diferentes.
JOB="${1:?uso: estagios-executados.sh <job>}"
T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

cat > /tmp/ee.groovy <<GROOVY
import jenkins.model.Jenkins
def b = Jenkins.instance.getItemByFullName('$JOB')?.getLastBuild()
def s = new StringBuilder()
def l = b.getLog(40000)
def atual = null
def pulado = [:]
def ordem = []
l.each { x ->
  def m = (x =~ /\\[Pipeline\\] \\{ \\((.+)\\)/)
  if (m) { atual = m[0][1]; if (!ordem.contains(atual)) ordem << atual }
  if (atual && x.contains('skipped due to')) {
    pulado[atual] = x.replaceAll(/.*skipped due to /, '').take(40)
  }
}
s << "  build #" + b.number + "  " + b.getResult() + "  " + (b.getDuration()/1000) + "s\n\n"
ordem.each { n ->
  s << (pulado[n] ? "  PULADO   " : "  EXECUTOU ") + n.padRight(34) +
       (pulado[n] ?: "") + "\n"
}
println s.toString()
null
GROOVY

curl -s -m 90 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/ee.groovy" "$J/scriptText" 2>&1 | head -25
rm -f "$CK" /tmp/ee.groovy

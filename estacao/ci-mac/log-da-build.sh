#!/bin/sh
# Ultimas linhas do log da build (a build viva inclusive).
JOB="${1:?uso: log-da-build.sh <job> [linhas]}"
N="${2:-60}"
T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

cat > /tmp/lg.groovy <<GROOVY
import jenkins.model.Jenkins
def b = Jenkins.instance.getItemByFullName('$JOB')?.getLastBuild()
def s = new StringBuilder()
if (b == null) { s << "sem build" }
else {
  def l = b.getLog(2000)
  def ini = Math.max(0, l.size() - $N)
  l[ini..<l.size()].each { s << "  " + it.take(150) + "\n" }
}
println s.toString()
null
GROOVY

curl -s -m 90 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/lg.groovy" "$J/scriptText" 2>&1
rm -f "$CK" /tmp/lg.groovy

#!/bin/sh
# Aborta a build em execucao de um job.
JOB="${1:?uso: abortar-build.sh <job>}"
T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

cat > /tmp/ab.groovy <<GROOVY
import jenkins.model.Jenkins
def b = Jenkins.instance.getItemByFullName('$JOB')?.getLastBuild()
if (b == null) { println "  sem build" }
else if (!b.isBuilding()) { println "  build #" + b.number + " ja' terminou (" + b.getResult() + ")" }
else {
  b.doStop()
  println "  parada solicitada para a build #" + b.number
  // ⚠️ `doStop` pede educadamente. Se o passo estiver preso em I/O, ele nao
  // sai -- por isso o `doTerm` logo em seguida como reforco.
  sleep(4000)
  if (b.isBuilding()) { b.doTerm(); println "  ainda viva: mandei doTerm" }
}
GROOVY

curl -s -m 60 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/ab.groovy" "$J/scriptText" 2>&1 | head -8
rm -f "$CK" /tmp/ab.groovy

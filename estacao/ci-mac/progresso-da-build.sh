#!/bin/sh
# Ha' quanto tempo a build corre, e em que estagio ela esta'.
#
# ⚠️ `getDuration()` devolve 0 enquanto a build NAO terminou -- por isso o
# tempo decorrido sai de `getStartTimeInMillis()`. Ler o `duration` de uma
# build viva devolve "0s", que parece instantanea e nao e'.
JOB="${1:?uso: progresso-da-build.sh <job>}"
T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

cat > /tmp/pg.groovy <<GROOVY
import jenkins.model.Jenkins
def s = new StringBuilder()
def b = Jenkins.instance.getItemByFullName('$JOB')?.getLastBuild()
if (b == null) { s << "  sem build\n" }
else {
  def viva = b.isBuilding()
  def decorrido = viva ? ((System.currentTimeMillis() - b.getStartTimeInMillis())/1000) as long
                       : (b.getDuration()/1000) as long
  s << "  build #" + b.number + "  " + (viva ? "RODANDO" : b.getResult()) +
       "  decorrido=" + decorrido + "s\n"
  // Ultimos passos executados, para saber ONDE ela esta'.
  try {
    def linhas = b.getLog(400).findAll { it =~ /^\[Pipeline\] \{ \(|^\+ / }
    def ultimas = linhas.size() > 8 ? linhas[-8..-1] : linhas
    s << "  ultimos passos:\n"
    ultimas.each { s << "    " + it.take(96) + "\n" }
  } catch (e) { s << "  (log indisponivel: " + e.message + ")\n" }
}
println s.toString()
null
GROOVY

curl -s -m 60 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/pg.groovy" "$J/scriptText" 2>&1 | head -20
rm -f "$CK" /tmp/pg.groovy

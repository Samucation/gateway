#!/bin/sh
# Acha a PRIMEIRA falha real no log, e nao o eco dela nos estagios pulados.
#
# ⚠️ "Stage skipped due to earlier failure" aparece dezenas de vezes e empurra
# a causa para fora da janela do log. Quem interessa e' a primeira linha de
# erro DE VERDADE.
JOB="${1:?uso: achar-a-falha.sh <job>}"
T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

cat > /tmp/af.groovy <<GROOVY
import jenkins.model.Jenkins
def b = Jenkins.instance.getItemByFullName('$JOB')?.getLastBuild()
def s = new StringBuilder()
if (b == null) { s << "sem build" }
else {
  def l = b.getLog(4000)
  // Onde cada estagio comecou
  s << "== estagios executados ==\n"
  l.each { if (it =~ /\[Pipeline\] \{ \(/ && !(it =~ /skipped/)) s << "  " + it.take(110) + "\n" }
  s << "\n== primeiras linhas de erro ==\n"
  def n = 0
  for (int i = 0; i < l.size() && n < 18; i++) {
    def x = l[i]
    if (x =~ /(?i)(ERRO|ERROR|FAIL|Exception|nao consegui|command not found|No such|denied|refused)/ &&
        !(x =~ /skipped due to earlier/) && !(x =~ /Antes de culpar/)) {
      s << "  " + x.take(140) + "\n"; n++
    }
  }
}
println s.toString()
null
GROOVY

curl -s -m 90 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/af.groovy" "$J/scriptText" 2>&1 | head -45
rm -f "$CK" /tmp/af.groovy

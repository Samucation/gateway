#!/bin/sh
# O multibranch do cartorio descobre quais branches?
#
# ⚠️ Se houver filtro para `main`, um branch de teste NUNCA vira job -- e o
# sintoma e' "o branch nao apareceu", que se le' como falha de varredura.
T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

cat > /tmp/f.groovy <<'GROOVY'
import jenkins.model.Jenkins
def s = new StringBuilder()
def mb = Jenkins.instance.getItemByFullName('cartorio-conceicao')
s << "  classe: " + mb.class.name + "\n"
mb.getSCMSources().each { src ->
    s << "  fonte : " + src.class.simpleName + "\n"
    try { s << "  repo  : " + src.getRemote() + "\n" } catch (e) {}
    try {
        src.getTraits().each { t ->
            s << "    trait: " + t.class.simpleName
            try { s << "  (" + t.getIncludes() + " / exclui: " + t.getExcludes() + ")" } catch (e2) {}
            s << "\n"
        }
    } catch (e) { s << "    (sem traits legiveis)\n" }
}
s << "  branches conhecidos: " + mb.getItems().collect{ it.name }.join(', ') + "\n"
println s.toString()
null
GROOVY

curl -s -m 60 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/f.groovy" "$J/scriptText" 2>&1 | head -30
rm -f "$CK" /tmp/f.groovy

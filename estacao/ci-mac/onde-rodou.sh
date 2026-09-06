#!/bin/sh
# ONDE a build rodou de verdade, e com QUAL parametro.
#
# 🐞 `buildWithParameters` devolve 400 enquanto o job nunca rodou: o Jenkins
# so' registra os parametros DEPOIS da primeira execucao. O disparo cai para
# o padrao -- e o padrao aqui e' `AGENTE_CI=''`, o built-in.
#
# ⚠️ Ou seja: da' para achar que testou no Mac e ter testado na estacao. Por
# isso a conferencia e' pelo NO' que EXECUTOU, e nao pelo comando enviado.
JOB="${1:?uso: onde-rodou.sh <job>}"
T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

cat > /tmp/od.groovy <<GROOVY
import jenkins.model.Jenkins
import hudson.model.ParametersAction
import org.jenkinsci.plugins.workflow.graphanalysis.DepthFirstScanner
import org.jenkinsci.plugins.workflow.actions.WorkspaceAction

def s = new StringBuilder()
def j = Jenkins.instance.getItemByFullName('$JOB')
j?.getBuilds()?.each { b ->
    s << "  build #" + b.number + "  " + b.getResult() + "  " + (b.getDuration()/1000) + "s\n"
    def pa = b.getAction(ParametersAction.class)
    s << "    parametros: " + (pa ? pa.getParameters().collect{ it.name + "='" + it.value + "'" }.join(', ') : '(nenhum)') + "\n"
    def nos = [] as Set
    try {
        def sc = new DepthFirstScanner()
        sc.setup(b.getExecution().getCurrentHeads())
        sc.each { n ->
            def wa = n.getAction(WorkspaceAction.class)
            if (wa != null) { nos << (wa.getNode() ?: 'built-in') }
        }
    } catch (e) { s << "    (nao li o grafo: " + e.message + ")\n" }
    s << "    EXECUTOU no(s) no(s): " + (nos ? nos.join(', ') : '?') + "\n\n"
}
println s.toString()
null
GROOVY

curl -s -m 60 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/od.groovy" "$J/scriptText" 2>&1 | head -25
rm -f "$CK" /tmp/od.groovy

#!/bin/sh
# Ultimas builds de cada esteira: preciso de uma LINHA DE BASE verde antes de
# duplicar qualquer pipeline.
#
# ⚠️ Migrar uma esteira que ja' esta' vermelha e depois ve-la vermelha no Mac
# nao prova nada -- e ainda faz parecer que o agente novo quebrou algo.
T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

cat > /tmp/b.groovy <<'GROOVY'
import jenkins.model.Jenkins
import org.jenkinsci.plugins.workflow.job.WorkflowJob

// ⚠️ `printf` NAO aparece na saida do console de scripts -- so' `println`
// e' capturado. Com printf o script "roda" e devolve o valor do `each`,
// que parece resultado e nao e'.
def saida = new StringBuilder()
Jenkins.instance.getAllItems(WorkflowJob.class).sort{ it.fullName }.each { j ->
    def hist = []
    j.getBuilds().limit(3).each { b ->
        hist << ("#" + b.number + ":" + (b.isBuilding() ? 'RODANDO' : b.getResult()))
    }
    saida << "  " + j.fullName.padRight(34) + (hist ? hist.join('  ') : '(nunca rodou)') + "\n"
}
println saida.toString()
null
GROOVY

curl -s -m 60 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/b.groovy" "$J/scriptText" 2>&1 | head -30
rm -f "$CK" /tmp/b.groovy

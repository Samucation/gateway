#!/bin/sh
# Cria um job DESCARTAVEL que roda o Jenkinsfile de um branch especifico.
#
#   sh criar-job-de-teste.sh <multibranch-de-origem> <branch> <nome-do-job>
#
# ⚠️ Por que um job novo, e nao mexer no multibranch: a fonte dele tem um
# `RegexSCMHeadFilterTrait` que so' descobre `main`, DE PROPOSITO. Afrouxar
# esse filtro para testar faria toda branch futura virar job -- e eu teria
# mudado a configuracao de producao para conveniencia minha.
#
# ⚠️ Num job avulso `BRANCH_NAME` fica indefinido, entao todo
# `when { branch 'main' }` da' FALSO e os estagios de deploy sao pulados. E'
# o que queremos: exercitar o CI sem implantar no site do cliente.
set -e
ORIGEM="${1:?uso: criar-job-de-teste.sh <multibranch> <branch> <nome>}"
BR="${2:?}"
NOME="${3:?}"

T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

cat > /tmp/cj.groovy <<GROOVY
import jenkins.model.Jenkins
import org.jenkinsci.plugins.workflow.job.WorkflowJob
import org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition
import hudson.plugins.git.GitSCM
import hudson.plugins.git.BranchSpec
import hudson.plugins.git.UserRemoteConfig

def origem = Jenkins.instance.getItemByFullName('$ORIGEM')
def src = origem.getSCMSources()[0]
def remoto = src.getRemote()
def cred = src.getCredentialsId()
println "  repo : \${remoto}"
println "  cred : \${cred}"

def ja = Jenkins.instance.getItemByFullName('$NOME')
if (ja != null) { ja.delete(); println "  (job anterior removido)" }

def scm = new GitSCM(
    [new UserRemoteConfig(remoto, null, null, cred)],
    [new BranchSpec('*/$BR')],
    null, null, [])

def job = Jenkins.instance.createProject(WorkflowJob.class, '$NOME')
job.setDefinition(new CpsScmFlowDefinition(scm, 'Jenkinsfile'))
job.setDescription('DESCARTAVEL: roda o Jenkinsfile do branch $BR. Estagios de deploy sao pulados (BRANCH_NAME indefinido).')
job.save()
println "  job '$NOME' criado apontando para o branch '$BR'"
GROOVY

curl -s -m 90 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/cj.groovy" "$J/scriptText" 2>&1 | head -20
rm -f "$CK" /tmp/cj.groovy

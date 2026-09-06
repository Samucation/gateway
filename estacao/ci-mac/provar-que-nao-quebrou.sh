#!/bin/sh
# ===========================================================================
# Prova que acrescentar o agente Mac NAO mudou as esteiras existentes.
#
#     wsl -d prd -u root -- sh .../ci-mac/provar-que-nao-quebrou.sh
#     wsl -d prd -u root -- sh .../ci-mac/provar-que-nao-quebrou.sh --com-build
#
# Sem argumento faz a conferencia ESTATICA (rapida, nao ocupa executor).
# Com `--com-build` roda um job de verdade e olha ONDE ele caiu -- que e' a
# unica prova que vale de fato.
#
# ⚠️ `--com-build` entra na FILA. Com 1 executor no built-in e esteiras
# esperando, ele pode demorar. Rode quando a fila estiver vazia.
# ===========================================================================
set -e
T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080

echo "== 1. modo de cada no' =="
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" \
        | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

cat > /tmp/modos.groovy <<'GROOVY'
import jenkins.model.Jenkins
import hudson.model.Node

def erros = []

println "  built-in : modo=${Jenkins.instance.mode} executores=${Jenkins.instance.numExecutors}"
if (Jenkins.instance.mode != Node.Mode.NORMAL) {
    erros << "o built-in NAO esta NORMAL -- 'agent any' deixaria de achar executor"
}

Jenkins.instance.nodes.each { n ->
    println "  ${n.nodeName.padRight(9)}: modo=${n.mode} executores=${n.numExecutors} labels='${n.labelString}'"
    if (n.nodeName != 'built-in' && n.mode != Node.Mode.EXCLUSIVE) {
        erros << "o no' '${n.nodeName}' esta ${n.mode}: 'agent any' pode cair nele"
    }
}

println ""
println "== 2. quem 'agent any' consegue pegar =="
// Tarefa sem label e' o que `agent any` produz. Jenkins so' a manda para no'
// em modo NORMAL -- e' exatamente essa a garantia que estamos conferindo.
def livres = []
livres << 'built-in (' + Jenkins.instance.mode + ')'
Jenkins.instance.nodes.each { n ->
    if (n.mode == Node.Mode.NORMAL) { livres << n.nodeName + ' (NORMAL)' }
}
println "  candidatos a 'agent any': " + livres.join(', ')
if (livres.size() > 1) {
    erros << "mais de um candidato para 'agent any' -- build pode sortear arquitetura"
}

println ""
if (erros) {
    println "RESULTADO: VERMELHO"
    erros.each { println "  X " + it }
} else {
    println "RESULTADO: VERDE -- 'agent any' so' pode cair no built-in (amd64)."
}
GROOVY

curl -s -m 40 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/modos.groovy" "$J/scriptText"
rm -f /tmp/modos.groovy

if [ "${1:-}" != "--com-build" ]; then
  rm -f "$CK"
  echo
  echo "(para a prova com build de verdade: --com-build)"
  exit 0
fi

# -------------------------------------------------------------------------
echo
echo "== 3. prova COM BUILD: um job 'agent any' tem de cair no built-in =="
JOB=zz-prova-agent-any

cat > /tmp/job.xml <<'XML'
<flow-definition plugin="workflow-job">
  <description>Descartavel: prova que 'agent any' nao vai para o Mac.</description>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script>
pipeline {
  agent any
  stages {
    stage('onde eu cai') {
      steps {
        sh 'echo "no=$NODE_NAME"; echo "arquitetura=$(uname -m)"'
      }
    }
  }
}
    </script>
    <sandbox>false</sandbox>
  </definition>
</flow-definition>
XML

curl -s -m 30 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  -H 'Content-Type: application/xml' --data-binary @/tmp/job.xml \
  "$J/createItem?name=$JOB" -o /dev/null -w '  criar job: HTTP %{http_code}\n'

curl -s -m 30 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  -X POST "$J/job/$JOB/build" -o /dev/null -w '  disparar: HTTP %{http_code}\n'

echo "  esperando terminar (ate 10 min; pode ficar na fila)..."
i=0
while [ $i -lt 60 ]; do
  R=$(curl -s -m 20 -u "samuca:$T" "$J/job/$JOB/lastBuild/api/json" 2>/dev/null)
  RES=$(echo "$R" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
  if [ -n "$RES" ]; then
    NO=$(echo "$R" | grep -o '"builtOn":"[^"]*"' | cut -d'"' -f4)
    echo "  resultado=$RES  caiu no no'='${NO:-built-in}'"
    case "${NO:-built-in}" in
      ''|'built-in') echo "  VERDE: 'agent any' foi para o built-in, como antes." ;;
      *)             echo "  VERMELHO: caiu em '$NO' -- o EXCLUSIVE nao esta valendo!" ;;
    esac
    break
  fi
  sleep 10
  i=$((i+1))
done

curl -s -m 30 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  -X POST "$J/job/$JOB/doDelete" -o /dev/null -w '  apagar job de prova: HTTP %{http_code}\n'
rm -f "$CK" /tmp/job.xml

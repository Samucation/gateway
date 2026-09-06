#!/bin/sh
# Dispara um job com AGENTE_CI e acompanha ate' terminar, mostrando o tempo
# de cada estagio -- que e' o numero que a decisao da Fase 4 precisa.
#
#   sh disparar-e-acompanhar.sh <job> <label-do-agente>
set -e
JOB="${1:?uso: disparar-e-acompanhar.sh <job> <label>}"
LABEL="${2:-mac-arm}"

T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

g() { curl -s -m 90 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
        --data-urlencode "script@$1" "$J/scriptText"; }

echo "== disparando '$JOB' com AGENTE_CI='$LABEL' =="
COD=$(curl -s -m 60 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  -X POST "$J/job/$JOB/buildWithParameters" \
  --data-urlencode "AGENTE_CI=$LABEL" \
  -o /dev/null -w '%{http_code}')
echo "  HTTP $COD"

# 🐞 NAO CAIR PARA O PADRAO EM SILENCIO.
#
# `buildWithParameters` devolve 400 enquanto o job nunca rodou -- o Jenkins so'
# registra os parametros DEPOIS da primeira execucao. A versao anterior deste
# script tratava isso agendando uma build simples, que roda com AGENTE_CI
# VAZIO: eu disparei "no Mac" e a build rodou no built-in, com SUCCESS. Quase
# reportei um teste que nao aconteceu.
#
# ⚠️ Agora ele PARA. Rodar no lugar errado com cara de certo e' pior que nao
# rodar.
case "$COD" in
  201|200|302) ;;
  400) echo "  ERRO: o job ainda nao registrou parametros (primeira execucao)."
       echo "        Rode uma vez sem parametro, depois repita com o label."
       rm -f "$CK"; exit 1 ;;
  *)   echo "  ERRO: disparo recusado (HTTP $COD)"; rm -f "$CK"; exit 1 ;;
esac
sleep 3
cat > /tmp/est.groovy <<GROOVY
import jenkins.model.Jenkins
def j = Jenkins.instance.getItemByFullName('$JOB')
def b = j?.getLastBuild()
// ⚠️ NAO agenda nada aqui. Este bloco so' OBSERVA -- foi agendar por conta
// propria que fez a build rodar no no' errado.
if (b == null) { println "SEM-BUILD" }
else if (b.isBuilding()) { println "RODANDO #" + b.number }
else { println "PARADA ultima=#" + b.number + " " + b.getResult() }
GROOVY
g /tmp/est.groovy | head -3

echo
echo "== acompanhando =="
# 🐞 ESPERAR A BUILD *NOVA*, e nao a ultima que existir.
#
# A versao anterior perguntava "a ultima build parou?" logo apos disparar.
# A nova ainda estava na FILA, entao a resposta falava da ANTERIOR -- que ja'
# tinha terminado. O laco saia na primeira volta anunciando um resultado que
# nao era o desta execucao.
#
# ⚠️ Mesma familia do defeito do disparo: medir a coisa errada e reportar com
# confianca. Agora o alvo e' o NUMERO da build, fixado antes de esperar.
ANTES=$(g /tmp/est.groovy | tr -d '\r' | head -1 | grep -oE '#[0-9]+' | tr -d '#')
ANTES=${ANTES:-0}
ALVO=$((ANTES + 1))
echo "  esperando a build #$ALVO (a anterior era #$ANTES)"

i=0
while [ $i -lt 180 ]; do
  S=$(g /tmp/est.groovy | tr -d '\r' | head -1)
  N=$(echo "$S" | grep -oE '#[0-9]+' | tr -d '#')
  case "$S" in
    *PARADA*) [ "${N:-0}" -ge "$ALVO" ] && { echo "  $S"; break; } ;;
    *)        [ $((i % 6)) = 0 ] && echo "  $S" ;;
  esac
  sleep 20; i=$((i+1))
done

echo
echo "== tempo por estagio =="
cat > /tmp/tempos.groovy <<GROOVY
import jenkins.model.Jenkins
import org.jenkinsci.plugins.workflow.job.WorkflowRun
def b = Jenkins.instance.getItemByFullName('$JOB')?.getLastBuild()
def s = new StringBuilder()
if (b == null) { println "  sem build" }
else {
  s << "  build #" + b.number + "  resultado=" + b.getResult() +
       "  total=" + (b.getDuration()/1000) + "s\n"
  try {
    def visitor = new org.jenkinsci.plugins.workflow.support.visualization.table.FlowGraphTable(b)
    visitor.build()
    visitor.getRows().each { r ->
      if (r.getNode() instanceof org.jenkinsci.plugins.workflow.cps.nodes.StepStartNode) {
        def nome = r.getDisplayName()
        if (nome && r.getDurationMillis() > 1000) {
          s << "    " + nome.take(46).padRight(48) + (r.getDurationMillis()/1000) + "s\n"
        }
      }
    }
  } catch (e) { s << "    (nao consegui detalhar: " + e.message + ")\n" }
  println s.toString()
}
null
GROOVY
g /tmp/tempos.groovy | head -30

rm -f "$CK" /tmp/est.groovy /tmp/tempos.groovy

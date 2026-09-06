#!/bin/sh
# ===========================================================================
# Aponta o no' `mac-arm` para o Java certo e para um PATH que enxergue o
# runtime de conteiner -- e entao liga o agente.
#
#     wsl -d prd -u root -- sh .../ci-mac/ajustar-e-ligar-no.sh
# ===========================================================================
#
# 🐞 DUAS ARMADILHAS DE AGENTE macOS, MEDIDAS EM 06/09/2026
#
# 1. PATH. A sessao SSH NAO INTERATIVA que o Jenkins abre nao le' `~/.zshrc`
#    nem `~/.zprofile`. O PATH que chega e' so:
#
#        /Users/<u>/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin
#
#    Sem `/opt/homebrew/bin`, sem `~/.orbstack/bin`. O `docker` funciona
#    quando a pessoa testa no terminal e SOME para o Jenkins -- estagio
#    quebrando com "command not found" sem nada ter mudado. Por isso o PATH
#    e' declarado no no', e nao herdado.
#
# 2. JAVA. O Mac tinha JDK 19 e 8, ambos build **x86_64** rodando sob
#    Rosetta. O Jenkins 2.568 nao suporta o 19, e um agente emulado paga
#    traducao em tudo. Instalamos o `openjdk@21` nativo arm64 e apontamos
#    para ele EXPLICITAMENTE -- senao o agente pega o `java` do PATH, que e'
#    o 19 emulado.
set -e

JAVA_MAC=/opt/homebrew/opt/openjdk@21/bin/java
T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" \
        | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

cat > /tmp/ajustar.groovy <<GROOVY
import jenkins.model.Jenkins
import hudson.plugins.sshslaves.SSHLauncher
import hudson.slaves.EnvironmentVariablesNodeProperty
import hudson.slaves.EnvironmentVariablesNodeProperty.Entry

def no = Jenkins.instance.getNode('mac-arm')
if (no == null) { println "ERRO: no' 'mac-arm' nao existe"; return }

// ---- Java explicito -------------------------------------------------------
def l = no.getLauncher()
if (l instanceof SSHLauncher) {
    l.setJavaPath('$JAVA_MAC')
    println "  java do agente: $JAVA_MAC"
} else {
    // ⚠️ \$ escapado: este heredoc NAO e' citado (precisa expandir \$JAVA_MAC),
    // entao todo \${...} do Groovy tem de ser protegido do shell.
    println "  AVISO: lancador nao e' SSHLauncher: " + (l == null ? 'nulo' : l.class.simpleName)
}

// ---- PATH declarado no no' ------------------------------------------------
// Ordem pensada: OrbStack primeiro (e' o runtime escolhido), Homebrew
// depois, e o basico do sistema no fim.
def caminho = '/Users/samuelferreiraduarte/.orbstack/bin:' +
              '/opt/homebrew/bin:/opt/homebrew/sbin:' +
              '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'

def props = no.getNodeProperties()
props.removeAll(EnvironmentVariablesNodeProperty.class)
props.add(new EnvironmentVariablesNodeProperty(
    new Entry('PATH', caminho),
    new Entry('JAVA_HOME', '/opt/homebrew/opt/openjdk@21'),
    // ⚠️ Sem isto o buildx do Docker Desktop antigo pode assumir o socket.
    new Entry('DOCKER_BUILDKIT', '1')))
println "  PATH do no' declarado"

Jenkins.instance.updateNode(no)
println "  no' salvo"
GROOVY

echo "== ajustando o no' =="
curl -s -m 60 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/ajustar.groovy" "$J/scriptText"

echo
echo "== mandando conectar =="
cat > /tmp/ligar.groovy <<'GROOVY'
import jenkins.model.Jenkins
def c = Jenkins.instance.getComputer('mac-arm')
if (c == null) { println "  sem computador 'mac-arm'"; return }
if (c.isOnline()) { println "  ja esta ONLINE" }
else { c.connect(true); println "  conexao disparada" }
GROOVY
curl -s -m 60 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/ligar.groovy" "$J/scriptText"

echo
echo "== esperando ficar online (ate 3 min) =="
i=0
while [ $i -lt 18 ]; do
  cat > /tmp/ver.groovy <<'GROOVY'
import jenkins.model.Jenkins
def c = Jenkins.instance.getComputer('mac-arm')
println c?.isOnline() ? 'ONLINE' : 'offline'
GROOVY
  S=$(curl -s -m 30 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
      --data-urlencode "script@/tmp/ver.groovy" "$J/scriptText" | tr -d '\r\n ')
  if [ "$S" = "ONLINE" ]; then echo "  ✅ agente ONLINE"; break; fi
  sleep 10
  i=$((i+1))
done
[ "$S" = "ONLINE" ] || {
  echo "  ainda offline -- log do agente:"
  cat > /tmp/log.groovy <<'GROOVY'
import jenkins.model.Jenkins
println Jenkins.instance.getComputer('mac-arm')?.getLog() ?: '(sem log)'
GROOVY
  curl -s -m 30 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
    --data-urlencode "script@/tmp/log.groovy" "$J/scriptText" | tail -25 | sed 's/^/    /'
}

rm -f "$CK" /tmp/ajustar.groovy /tmp/ligar.groovy /tmp/ver.groovy /tmp/log.groovy

#!/bin/sh
# Retrato dos agentes: quem existe, capacidade, e o que cada um aceita.
T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

cat > /tmp/ag.groovy <<'GROOVY'
import jenkins.model.Jenkins
import hudson.model.Node

def s = new StringBuilder()
def total = 0, livres = 0

def linha = { nome, modo, exec, ocup, online, labels, onde ->
    total += exec
    livres += (exec - ocup)
    s << "  " + nome.padRight(11) +
         (online ? "ONLINE " : "offline") +
         "  modo=" + modo.toString().padRight(9) +
         "  executores=" + exec + " (ocupados: " + ocup + ")" +
         "\n               labels: " + labels +
         "\n               onde  : " + onde + "\n\n"
}

def c0 = Jenkins.instance.toComputer()
linha('built-in', Jenkins.instance.mode, Jenkins.instance.numExecutors,
      c0.countBusy(), c0.isOnline(), 'built-in',
      'a propria distro `prd` -- a MESMA maquina que roda a producao')

Jenkins.instance.nodes.each { n ->
    def c = n.toComputer()
    linha(n.nodeName, n.mode, n.numExecutors, c?.countBusy() ?: 0,
          c?.isOnline() ?: false, n.labelString,
          n.getRootPath()?.getRemote() ?: '(desconectado)')
}

s << "  CAPACIDADE TOTAL: " + total + " executores (" + livres + " livres agora)\n\n"

s << "  Quem 'agent any' pode pegar (so' modo NORMAL):\n"
def cands = ['built-in (NORMAL)']
Jenkins.instance.nodes.each { n -> if (n.mode == Node.Mode.NORMAL) cands << n.nodeName }
s << "    " + cands.join(', ') + "\n"
println s.toString()
null
GROOVY

curl -s -m 60 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/ag.groovy" "$J/scriptText" 2>&1 | head -30
rm -f "$CK" /tmp/ag.groovy

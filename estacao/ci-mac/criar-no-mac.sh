#!/bin/sh
# ===========================================================================
# Cria o no' `mac-arm` no Jenkins, em modo EXCLUSIVE.
#
#     wsl -d prd -u root -- sh .../ci-mac/criar-no-mac.sh <host-ou-ip> <usuario>
#
# ---------------------------------------------------------------------------
# ⚠️ O `EXCLUSIVE` E' A PECA QUE IMPEDE DE QUEBRAR O QUE JA' FUNCIONA
# ---------------------------------------------------------------------------
# TODOS os Jenkinsfiles da casa usam `agent any`, e `agent any` so' escolhe
# no' em modo NORMAL. Um no' EXCLUSIVE so' aceita job cujo label CASA com o
# dele.
#
# Consequencia pratica: com o no' criado assim, NENHUMA esteira existente
# muda de comportamento -- elas continuam todas no built-in, como hoje. A
# migracao vira opt-in, um pipeline por vez, e se desfaz apagando um label.
#
# 🐞 Se um dia alguem trocar este modo para NORMAL, as 12 esteiras passam a
# sortear entre built-in (amd64) e Mac (arm64) -- e as que cairem no Mac vao
# gerar imagem que NAO RODA no cluster, falhando so' na hora de subir o Pod.
# Nao mude sem ler o cabecalho de `preparar-mac.sh`.
# ===========================================================================
set -e

HOST="${1:?uso: criar-no-mac.sh <host-ou-ip> <usuario>}"
USUARIO="${2:?uso: criar-no-mac.sh <host-ou-ip> <usuario>}"
NOME=mac-arm

T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" \
        | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

cat > /tmp/no.groovy <<GROOVY
import hudson.model.Node
import hudson.slaves.DumbSlave
import hudson.slaves.RetentionStrategy
import hudson.plugins.sshslaves.SSHLauncher
import hudson.plugins.sshslaves.verifiers.ManuallyTrustedKeyVerificationStrategy
import jenkins.model.Jenkins

def nome = '$NOME'
if (Jenkins.instance.getNode(nome) != null) {
    println "no' '\${nome}' ja existe -- nada a fazer"
    return
}

// TOFU: confia na chave da primeira conexao e a FIXA dali em diante. Numa
// rede local e' aceitavel; e depois de fixada, troca de chave passa a ser
// recusada, que e' o que interessa.
def lanc = new SSHLauncher('$HOST', 22, 'ci-mac-ssh')
lanc.setSshHostKeyVerificationStrategy(new ManuallyTrustedKeyVerificationStrategy(false))

def no = new DumbSlave(nome, '/Users/$USUARIO/jenkins-agente', lanc)
no.setNodeDescription('MacBook M1 Max (arm64) - agente de CI. EXCLUSIVE de proposito.')

// Dois executores: o Mac tem 32 GB, e build emulado amd64 e' pesado. Comeca
// conservador; so' sobe depois de MEDIR.
no.setNumExecutors(2)
no.setLabelString('mac-arm arm64 orbstack')

// ⚠️ A LINHA QUE PROTEGE AS 12 ESTEIRAS ATUAIS. Ver o cabecalho do arquivo.
no.setMode(Node.Mode.EXCLUSIVE)

no.setRetentionStrategy(RetentionStrategy.INSTANCE)
Jenkins.instance.addNode(no)
println "no' '\${nome}' criado (EXCLUSIVE, 2 executores, labels: mac-arm arm64 orbstack)"
GROOVY

curl -s -m 60 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/no.groovy" "$J/scriptText"
rm -f "$CK" /tmp/no.groovy

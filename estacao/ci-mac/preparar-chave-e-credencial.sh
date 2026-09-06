#!/bin/sh
# ===========================================================================
# Gera a chave SSH DEDICADA do CI e a cadastra como credencial no Jenkins.
#
#     wsl -d prd -u root -- sh .../ci-mac/preparar-chave-e-credencial.sh
#
# ⚠️ CHAVE DEDICADA, e nao a pessoal. Ja existe a divida
# `divida-seguranca-chave-ssh-jenkins` justamente por ter usado a chave do
# dono num servico. Chave de servico se revoga sozinha, sem tirar o acesso de
# ninguem a mais -- e e' por isso que ela nasce separada aqui.
#
# ⚠️ Esta chave abre uma conta no Mac. Ela NAO deve ter frase secreta (o
# Jenkins conecta sozinho), entao o que a protege e' a permissao do arquivo e
# o fato de viver so' dentro do cofre do Jenkins.
# ===========================================================================
set -e

CHAVE=/var/lib/jenkins/.ssh/ci-mac
ID_CRED=ci-mac-ssh

install -d -m 700 -o jenkins -g jenkins /var/lib/jenkins/.ssh

if [ -f "$CHAVE" ]; then
  echo "== chave ja existe em $CHAVE -- reaproveitando =="
else
  echo "== gerando chave ed25519 dedicada =="
  ssh-keygen -t ed25519 -N '' -C 'jenkins-ci-mac' -f "$CHAVE" >/dev/null
  chown jenkins:jenkins "$CHAVE" "$CHAVE.pub"
  chmod 600 "$CHAVE"
  chmod 644 "$CHAVE.pub"
  echo "  criada"
fi

echo
echo "== cadastrando no cofre do Jenkins (id: $ID_CRED) =="
T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080
CK=$(mktemp)

# ⚠️ O crumb TEM de vir da MESMA sessao do POST. Crumb pego noutra sessao
# devolve 403, que se le' como "sem permissao" e nao e'.
CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" \
        | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

cat > /tmp/cred.groovy <<'GROOVY'
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.Domain
import com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey
import jenkins.model.Jenkins

def id = 'ci-mac-ssh'
def loja = Jenkins.instance.getExtensionList(
    'com.cloudbees.plugins.credentials.SystemCredentialsProvider')[0].getStore()

def ja = CredentialsProvider.lookupCredentialsInItemGroup(
    com.cloudbees.jenkins.plugins.sshcredentials.SSHUserPrivateKey.class,
    Jenkins.instance, null, null).find { it.id == id }
if (ja != null) { println "credencial '${id}' ja existe -- nada a fazer"; return }

def chave = new File('/var/lib/jenkins/.ssh/ci-mac').text
def fonte = new BasicSSHUserPrivateKey.DirectEntryPrivateKeySource(chave)

// ⚠️ USUARIO_DO_MAC e trocado pelo shell antes de enviar.
def cred = new BasicSSHUserPrivateKey(
    CredentialsScope.GLOBAL, id, 'USUARIO_DO_MAC', fonte, '',
    'Chave dedicada do CI para o agente MacBook (nao e a chave pessoal)')

loja.addCredentials(Domain.global(), cred)
println "credencial '${id}' criada para o usuario 'USUARIO_DO_MAC'"
GROOVY

USUARIO_MAC="${1:-samuel}"
sed -i "s/USUARIO_DO_MAC/$USUARIO_MAC/g" /tmp/cred.groovy

curl -s -m 40 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
  --data-urlencode "script@/tmp/cred.groovy" "$J/scriptText"
rm -f "$CK" /tmp/cred.groovy

echo
echo "==========================================================="
echo " COLE ESTA CHAVE PUBLICA NO MAC, em ~/.ssh/authorized_keys"
echo "==========================================================="
cat "$CHAVE.pub"
echo "==========================================================="
echo
echo "No Mac:"
echo "  mkdir -p ~/.ssh && chmod 700 ~/.ssh"
echo "  echo '<a linha acima>' >> ~/.ssh/authorized_keys"
echo "  chmod 600 ~/.ssh/authorized_keys"

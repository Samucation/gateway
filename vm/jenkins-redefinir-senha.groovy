/*
 * ===========================================================================
 * Redefine a senha de UM usuario do Jenkins, sem abrir a tela.
 *
 * Instalar em: /var/lib/jenkins/init.groovy.d/jenkins-redefinir-senha.groovy
 * E a senha em: /var/lib/jenkins/secrets/senha-nova   (600, dono jenkins)
 * Depois:      sudo systemctl restart jenkins
 *
 * ---------------------------------------------------------------------------
 * ⚠️ ELE SE APAGA DEPOIS DE USAR
 * ---------------------------------------------------------------------------
 * Script que redefine senha nao pode ficar em `init.groovy.d`: ele roda em TODA
 * partida do Jenkins, e a senha voltaria ao valor do arquivo toda vez que a
 * maquina reiniciasse -- desfazendo, em silencio, qualquer troca feita pela
 * tela depois.
 *
 * Por isso: usa o arquivo, apaga o arquivo, e apaga a SI MESMO. Se o arquivo
 * nao existir, ele nao faz nada.
 *
 * ---------------------------------------------------------------------------
 * O QUE ELE NAO FAZ
 * ---------------------------------------------------------------------------
 * Nao cria conta, nao mexe em permissao, nao toca em token de API. So troca a
 * senha de um login que JA existe -- e recusa se o login nao existir, em vez de
 * criar um por engano.
 * ===========================================================================
 */
import jenkins.model.Jenkins
import hudson.model.User
import hudson.security.HudsonPrivateSecurityRealm

def LOGIN   = 'samuca'
def ARQUIVO = new File('/var/lib/jenkins/secrets/senha-nova')
def EU      = new File('/var/lib/jenkins/init.groovy.d/jenkins-redefinir-senha.groovy')

if (!ARQUIVO.exists() || !ARQUIVO.text.trim()) {
    println "[senha] ${ARQUIVO} nao existe -- nada a fazer"
    return
}

def nova = ARQUIVO.text.trim()

def user = User.getById(LOGIN, false)
if (user == null) {
    println "[senha] ⚠️ o usuario '${LOGIN}' NAO existe -- nada foi criado nem alterado"
    return
}

// `HudsonPrivateSecurityRealm.Details.fromPlainPassword` gera o hash bcrypt no
// mesmo formato que a tela usaria. Escrever o hash a mao seria fragil e
// quebraria calado numa atualizacao do Jenkins.
user.addProperty(HudsonPrivateSecurityRealm.Details.fromPlainPassword(nova))
user.save()
println "[senha] senha de '${LOGIN}' redefinida"

// ⚠️ Apaga o arquivo: a senha em texto puro no disco entraria tambem nos
// backups, que e uma segunda copia que ninguem lembra de proteger.
if (ARQUIVO.delete()) println "[senha] arquivo da senha apagado"
else println "[senha] ⚠️ NAO consegui apagar ${ARQUIVO} -- apague a mao"

// ⚠️ E apaga a si mesmo, para nao redefinir de novo no proximo reinicio.
if (EU.delete()) println "[senha] o proprio script foi removido de init.groovy.d"
else println "[senha] ⚠️ REMOVA ${EU} a mao -- senao a senha volta a cada reinicio"

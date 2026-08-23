/*
 * ===========================================================================
 * As contas do Jenkins — criadas por CODIGO, e nao pela tela.
 *
 * Instalar em: /var/lib/jenkins/init.groovy.d/jenkins-usuarios.groovy
 * ---------------------------------------------------------------------------
 * 🐞 POR QUE ISTO EXISTE
 * ---------------------------------------------------------------------------
 * Na `serverhomol` as duas contas foram criadas na tela, uma vez, e nunca mais
 * pensadas. Quando a maquina saiu do ar e o Jenkins precisou ser levantado de
 * outro lugar, elas simplesmente NAO EXISTIAM -- e o script que cria o token de
 * API falhava com "usuario 'samuca' nao existe", que parece defeito do script.
 *
 * Configuracao que so mora na tela e configuracao que se perde.
 *
 * ---------------------------------------------------------------------------
 * ⚠️ AS SENHAS NAO FICAM AQUI
 * ---------------------------------------------------------------------------
 * Cada conta le a senha de um arquivo em `/var/lib/jenkins/secrets/`, modo 600.
 * Se o arquivo nao existir, o script SORTEIA uma senha, grava no arquivo e
 * avisa no log -- assim a conta nunca nasce com senha previsivel, e quem
 * instalou tem onde ler a primeira.
 *
 * ⚠️ Ele NAO troca a senha de conta que ja existe. Rodar de novo depois de voce
 * ter mudado a senha pela tela desfaria a troca em silencio, a cada reinicio.
 * ===========================================================================
 */
import jenkins.model.Jenkins
import hudson.security.HudsonPrivateSecurityRealm
import java.security.SecureRandom

def jenkins = Jenkins.get()
def realm = jenkins.getSecurityRealm()

if (!(realm instanceof HudsonPrivateSecurityRealm)) {
    println "[usuarios] o reino de seguranca nao e o interno do Jenkins -- nada a fazer"
    return
}

/** Uma senha que ninguem adivinha, para a conta nao nascer fraca. */
def sortear = {
    def alfabeto = ('a'..'z') + ('A'..'Z') + ('0'..'9') + ['!', '@', '#', '%', '+', '-', '=']
    def r = new SecureRandom()
    (1..24).collect { alfabeto[r.nextInt(alfabeto.size())] }.join('')
}

// `samuca` e a conta do dono; `claude-automacao` e a que o painel e os scripts
// usam para disparar, parar e responder ao portao de producao.
def CONTAS = ['samuca', 'claude-automacao']

CONTAS.each { login ->
    if (hudson.model.User.getById(login, false) != null) {
        println "[usuarios] '${login}' ja existe -- nao mexo na senha"
        return
    }

    def arquivo = new File("/var/lib/jenkins/secrets/senha-${login}")
    def senha
    if (arquivo.exists()) {
        senha = arquivo.text.trim()
        println "[usuarios] '${login}': senha lida de ${arquivo}"
    } else {
        senha = sortear()
        arquivo.text = senha
        // 600: so o dono do processo le. O arquivo fica para quem instalou
        // conseguir entrar da primeira vez.
        arquivo.setReadable(false, false)
        arquivo.setReadable(true, true)
        arquivo.setWritable(false, false)
        println "[usuarios] '${login}': senha SORTEADA e gravada em ${arquivo}"
    }

    realm.createAccount(login, senha)
    println "[usuarios] '${login}' criado"
}

jenkins.save()

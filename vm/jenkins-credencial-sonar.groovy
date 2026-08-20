/*
 * ===========================================================================
 * Cria a credencial do SonarQube no Jenkins, SEM abrir a tela.
 *
 * Instalar em: /var/lib/jenkins/init.groovy.d/jenkins-credencial-sonar.groovy
 * E o token em: /var/lib/jenkins/secrets/sonar-token   (600, dono jenkins)
 *
 * ---------------------------------------------------------------------------
 * ⚠️ POR QUE NAO HA PLUGIN DO SONAR AQUI
 * ---------------------------------------------------------------------------
 * O plugin oficial traz `withSonarQubeEnv` e `waitForQualityGate`. O segundo e
 * o problema: ele espera um WEBHOOK -- o Sonar precisa CHAMAR o Jenkins de
 * volta quando a analise termina.
 *
 * Nesta montagem isso seria uma peca fragil a mais: o Sonar roda DENTRO do
 * cluster e o Jenkins roda no HOST, escutando so em 127.0.0.1. Para o webhook
 * chegar, um Pod teria que alcancar a porta do host -- e no dia em que o IP da
 * rede do cluster mudar, o `waitForQualityGate` fica pendurado ate o tempo
 * limite, sem dizer por que.
 *
 * Entao as esteiras PERGUNTAM ao Sonar em vez de esperar por ele: consultam
 * `api/ce/task` ate a analise terminar e depois `api/qualitygates/project_status`.
 * Mais linhas de shell, nenhuma chamada de volta, e o erro -- quando houver --
 * aparece na hora e com nome.
 *
 * A credencial abaixo e o que essas consultas usam.
 * ===========================================================================
 */
import com.cloudbees.plugins.credentials.CredentialsScope
import com.cloudbees.plugins.credentials.SystemCredentialsProvider
import com.cloudbees.plugins.credentials.domains.Domain
import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl
import hudson.util.Secret

def ID_CRED = 'sonar-token'
def ARQUIVO = new File('/var/lib/jenkins/secrets/sonar-token')

if (!ARQUIVO.exists() || !ARQUIVO.text.trim()) {
    println "[sonar] ${ARQUIVO} nao existe ou esta vazio -- nada a fazer"
    return
}

def token    = ARQUIVO.text.trim()
def provider = SystemCredentialsProvider.getInstance()
def dominio  = Domain.global()
def atuais   = provider.getDomainCredentialsMap()[dominio] ?: []

// Remove a anterior antes de por a nova. Sem isto, rodar de novo com um token
// rotacionado criaria uma SEGUNDA credencial com o mesmo id -- e o Jenkins
// usaria uma das duas sem dizer qual.
def antiga = atuais.find { it.id == ID_CRED }
if (antiga) {
    provider.removeCredentials(dominio, antiga)
    println "[sonar] credencial anterior removida"
}

provider.addCredentials(dominio, new StringCredentialsImpl(
    CredentialsScope.GLOBAL,
    ID_CRED,
    'SonarQube — token de analise global (criado por init.groovy.d)',
    Secret.fromString(token)))
provider.save()

println "[sonar] credencial '${ID_CRED}' criada"

// ⚠️ O arquivo NAO e apagado, ao contrario do token do GitHub.
//
// A diferenca e proposital: este mesmo token e usado por scripts de manutencao
// rodando na VM (conferir a saude do Sonar, listar projetos), que nao tem como
// ler o cofre do Jenkins. Ele fica em modo 600, dono `jenkins`.

/*
 * ===========================================================================
 * Cria a credencial do GitHub no Jenkins, SEM abrir a tela.
 *
 * Instalar em:  /var/lib/jenkins/init.groovy.d/jenkins-credencial.groovy
 * E o token em: /var/lib/jenkins/secrets/github-token   (modo 600, dono jenkins)
 *
 * Depois: sudo systemctl restart jenkins
 *
 * ---------------------------------------------------------------------------
 * POR QUE ISTO EXISTE
 * ---------------------------------------------------------------------------
 * Cadastrar credencial pela tela exige a senha do Jenkins. Escrever o
 * `credentials.xml` a mao exige cifrar com a chave-mestra dele, o que e fragil
 * e quebra calado numa atualizacao.
 *
 * `init.groovy.d` e a porta oficial: o Jenkins executa estes scripts na
 * partida, com permissao total, ANTES de servir qualquer requisicao. E o
 * mecanismo pensado exatamente para configuracao automatizada.
 *
 * ---------------------------------------------------------------------------
 * ⚠️ O QUE ELE NAO FAZ, E NAO TEM COMO FAZER
 * ---------------------------------------------------------------------------
 * Ele nao CRIA o token. Isso exige a sua conta do GitHub, e nenhum automatismo
 * daqui alcanca aquela sessao.
 *
 * O que ele faz e tirar o Jenkins do caminho: com o token num arquivo, a
 * credencial nasce sozinha, com o `id` exato que a pasta de organizacao
 * procura -- sem ninguem digitar nada numa tela e sem chance de errar o id.
 *
 * ---------------------------------------------------------------------------
 * ⚠️ E O ARQUIVO DO TOKEN
 * ---------------------------------------------------------------------------
 * Ele fica no disco em texto puro ate o Jenkins ler. Por isso:
 *
 *   * modo 600 e dono `jenkins` -- so ele le;
 *   * o script APAGA o arquivo depois de importar. O token passa a viver so
 *     dentro do Jenkins, cifrado com a chave-mestra dele, que e onde ele deve
 *     estar.
 *
 * Se o arquivo nao existir, o script nao faz nada e nao reclama: e o estado
 * normal depois da primeira importacao.
 * ===========================================================================
 */
import com.cloudbees.plugins.credentials.CredentialsScope
import com.cloudbees.plugins.credentials.SystemCredentialsProvider
import com.cloudbees.plugins.credentials.domains.Domain
import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl
import com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl
import jenkins.model.Jenkins

def ID_CREDENCIAL = 'github-samucation'
def USUARIO       = 'Samucation'
def ARQUIVO       = new File('/var/lib/jenkins/secrets/github-token')

if (!ARQUIVO.exists()) {
    // Estado normal depois da primeira importacao. Nao e erro.
    println "[credencial] ${ARQUIVO} nao existe -- nada a fazer"
    return
}

def token = ARQUIVO.text.trim()
if (!token) {
    println "[credencial] ${ARQUIVO} esta vazio -- nada a fazer"
    return
}

def provider = SystemCredentialsProvider.getInstance()
def dominio  = Domain.global()
def atuais   = provider.getDomainCredentialsMap()[dominio] ?: []

// Remove a anterior antes de por a nova. Sem isto, rodar de novo com um token
// rotacionado criaria uma SEGUNDA credencial com o mesmo id -- e o Jenkins
// usaria uma das duas sem dizer qual.
def antiga = atuais.find { it.id == ID_CREDENCIAL }
if (antiga) {
    provider.removeCredentials(dominio, antiga)
    println "[credencial] a anterior com id '${ID_CREDENCIAL}' foi removida"
}

// `UsernamePassword` porque a pasta de organizacao do GitHub espera usuario +
// token. Um token de escopo fino vai no lugar da senha.
def nova = new UsernamePasswordCredentialsImpl(
    CredentialsScope.GLOBAL,
    ID_CREDENCIAL,
    'GitHub — token de escopo fino, somente leitura (criado por init.groovy.d)',
    USUARIO,
    token
)
provider.addCredentials(dominio, nova)
provider.save()

println "[credencial] '${ID_CREDENCIAL}' criada para o usuario ${USUARIO}"

// ⚠️ Apaga o arquivo. O token passa a viver so dentro do Jenkins, cifrado com a
// chave-mestra dele. Deixa-lo no disco em texto puro seria uma segunda copia
// permanente, e a que menos protecao tem.
if (ARQUIVO.delete()) {
    println "[credencial] o arquivo do token foi apagado do disco"
} else {
    println "[credencial] ⚠️ NAO consegui apagar ${ARQUIVO} -- apague a mao"
}

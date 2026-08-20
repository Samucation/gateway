/*
 * ===========================================================================
 * Gera um token de API do Jenkins para automacao, SEM abrir a tela.
 *
 * Instalar em: /var/lib/jenkins/init.groovy.d/jenkins-token-api.groovy
 * Escreve em:  /var/lib/jenkins/secrets/api-token   (600, dono jenkins)
 *
 * ---------------------------------------------------------------------------
 * POR QUE ISTO EXISTE
 * ---------------------------------------------------------------------------
 * Varias operacoes do Jenkins nao tem como ser feitas de dentro de um script
 * de `init.groovy.d` -- ele roda DURANTE a partida, antes de o escalonador e
 * a fila existirem. Disparar uma varredura ali e descartado sem erro e sem
 * log.
 *
 * 🐞 E tentar contornar com uma linha de execucao separada tambem falha, por
 * um motivo que custou tres tentativas para achar: dentro daquela linha o
 * carregador de classes e OUTRO, entao `it instanceof WorkflowMultiBranchProject`
 * devolve `false` para todos os jobs. A mensagem saia como
 * "varredura disparada em 0 job(s) de 0 encontrados" -- honesta, e facil de
 * ler como "nao ha jobs" em vez de "nao consigo reconhece-los".
 *
 * Com um token, essas operacoes saem por HTTP contra o Jenkins JA DE PE, que e
 * onde elas funcionam de verdade:
 *
 *     curl -u samuca:$(cat /var/lib/jenkins/secrets/api-token) \
 *          -X POST http://127.0.0.1:8080/job/<projeto>/build
 *
 * ⚠️ Pela porta 8080 direto, e NAO pelo tunel: o nginx apaga o cabecalho
 * `Authorization` (necessario para o navegador funcionar), entao a API REST
 * nao passa por la. De fora, use `ssh -L 8080:127.0.0.1:8080`.
 *
 * ---------------------------------------------------------------------------
 * ⚠️ O QUE ESTE TOKEN PODE
 * ---------------------------------------------------------------------------
 * Ele age COMO o usuario dono dele, que e administrador. Vale o mesmo cuidado
 * de qualquer credencial: modo 600, dono `jenkins`, e revogavel a qualquer
 * momento pela tela (Configurar > Tokens de API) sem mexer na senha.
 *
 * Ele NAO e regenerado a cada partida: se o arquivo ja existe, o script nao
 * faz nada. Sem isso, cada reinicio criaria mais um token na conta -- e a
 * lista viraria um monte de entradas que ninguem sabe se ainda estao em uso.
 * ===========================================================================
 */
import jenkins.model.Jenkins
import hudson.model.User
import jenkins.security.ApiTokenProperty

def ARQUIVO = new File('/var/lib/jenkins/secrets/api-token')
def LOGIN   = 'samuca'
def NOME    = 'automacao-esteiras'

if (ARQUIVO.exists() && ARQUIVO.text.trim()) {
    println "[token-api] ${ARQUIVO} ja existe -- nada a fazer"
    return
}

def user = User.getById(LOGIN, false)
if (user == null) {
    println "[token-api] ⚠️ usuario '${LOGIN}' nao existe -- token NAO criado"
    return
}

def prop = user.getProperty(ApiTokenProperty.class)
if (prop == null) {
    println "[token-api] ⚠️ '${LOGIN}' sem ApiTokenProperty -- token NAO criado"
    return
}

def resultado = prop.tokenStore.generateNewToken(NOME)
user.save()

ARQUIVO.text = resultado.plainValue
ARQUIVO.setReadable(false, false)
ARQUIVO.setReadable(true, true)
ARQUIVO.setWritable(false, false)

println "[token-api] token '${NOME}' criado para ${LOGIN} em ${ARQUIVO}"

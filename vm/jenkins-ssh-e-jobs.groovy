/*
 * ===========================================================================
 * Importa a chave SSH do GitHub e cria os 10 jobs, SEM abrir a tela.
 *
 * Instalar em: /var/lib/jenkins/init.groovy.d/jenkins-ssh-e-jobs.groovy
 * E a chave em: /var/lib/jenkins/secrets/github-ssh-key   (600, dono jenkins)
 * Depois:      sudo systemctl restart jenkins
 *
 * ===========================================================================
 * ⚠️⚠️  DIVIDA DE SEGURANCA CONSCIENTE -- LER ANTES DE MEXER  ⚠️⚠️
 * ===========================================================================
 * A chave importada aqui e a chave PESSOAL do Samuel (`id_ed25519`,
 * SHA256:blmlXuCMZ7UwfwJRTPSxQqjm+3O+HCDHBXHyOq/1iBQ). Ela tem ESCRITA em
 * todos os repositorios da conta Samucation.
 *
 * O usuario `jenkins` desta maquina esta nos grupos `docker` e `microk8s`, o
 * que na pratica e root aqui. Entao:
 *
 *   quem comprometer esta VM passa a ser o Samuel no GitHub,
 *   com poder de injetar codigo em qualquer repositorio dele.
 *
 * Isso e MAIS PODER do que o CI precisa. O CI so precisa LER.
 *
 * ---------------------------------------------------------------------------
 * POR QUE ESTA ASSIM, ENTAO
 * ---------------------------------------------------------------------------
 * A alternativa recomendada era um token de escopo fino (somente leitura), mas
 * ela exige a sessao do GitHub no navegador -- nao existe API para criar
 * Personal Access Token, de proposito. O Samuel optou por destravar o ambiente
 * agora e revisar seguranca depois, com o risco registrado. Decisao dele,
 * tomada com a informacao na mao.
 *
 * ---------------------------------------------------------------------------
 * COMO SAIR DESTA DIVIDA (o caminho ja esta pronto)
 * ---------------------------------------------------------------------------
 * 1. Criar o token de escopo fino -- passo a passo em system-api/k8s/jenkins.md.
 * 2. Entregar ao Jenkins: o `jenkins-credencial.groovy` ja esta instalado e
 *    cria a credencial `github-samucation` sozinho.
 * 3. A pasta de organizacao `github-Samucation` (que ja existe e ja aponta para
 *    essa credencial) passa a descobrir os repositorios pela API.
 * 4. Apagar ESTE arquivo, remover a credencial `github-ssh-samucation` e
 *    apagar os jobs que ele cria.
 * 5. ⚠️ E ROTACIONAR a chave `id_ed25519` no GitHub -- ela esteve nesta
 *    maquina, e "esteve" e para sempre.
 *
 * O que se perde ate la, alem da seguranca: DESCOBERTA. A API lista os
 * repositorios sozinha; por SSH nao da, entao os 10 jobs abaixo sao uma LISTA
 * ESCRITA A MAO. Projeto novo nao aparece sozinho -- tem que entrar aqui.
 * ===========================================================================
 */
import jenkins.model.Jenkins
import com.cloudbees.plugins.credentials.CredentialsScope
import com.cloudbees.plugins.credentials.SystemCredentialsProvider
import com.cloudbees.plugins.credentials.domains.Domain
import com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey
import jenkins.branch.BranchSource
import jenkins.plugins.git.GitSCMSource
import jenkins.scm.impl.trait.RegexSCMHeadFilterTrait
import org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject
import com.cloudbees.hudson.plugins.folder.computed.PeriodicFolderTrigger

def ID_CRED  = 'github-ssh-samucation'
def ARQUIVO  = new File('/var/lib/jenkins/secrets/github-ssh-key')

// ---------------------------------------------------------------------------
// 1. A CREDENCIAL
// ---------------------------------------------------------------------------
if (ARQUIVO.exists() && ARQUIVO.text.trim()) {
    def chave    = ARQUIVO.text
    def provider = SystemCredentialsProvider.getInstance()
    def dominio  = Domain.global()
    def atuais   = provider.getDomainCredentialsMap()[dominio] ?: []

    def antiga = atuais.find { it.id == ID_CRED }
    if (antiga) {
        provider.removeCredentials(dominio, antiga)
        println "[ssh] credencial anterior removida"
    }

    def cred = new BasicSSHUserPrivateKey(
        CredentialsScope.GLOBAL,
        ID_CRED,
        'git',
        new BasicSSHUserPrivateKey.DirectEntryPrivateKeySource(chave),
        null,   // sem senha
        'GitHub SSH — ⚠️ chave PESSOAL, tem ESCRITA. Ver jenkins-ssh-e-jobs.groovy')
    provider.addCredentials(dominio, cred)
    provider.save()
    println "[ssh] credencial '${ID_CRED}' criada"

    // ⚠️ Apaga o arquivo. A chave passa a viver so dentro do Jenkins, cifrada
    // com a chave-mestra dele. Em texto puro no disco ela entraria tambem nos
    // backups, que e uma segunda copia que ninguem lembra de proteger.
    if (ARQUIVO.delete()) {
        println "[ssh] arquivo da chave apagado do disco"
    } else {
        println "[ssh] ⚠️ NAO consegui apagar ${ARQUIVO} -- apague a mao"
    }
} else {
    println "[ssh] ${ARQUIVO} nao existe -- credencial nao mexida"
}

// ---------------------------------------------------------------------------
// 2. OS JOBS
//
// ⚠️ LISTA A MAO, e e por isso que o token e melhor. Com a API, esta lista nao
// existiria -- o Jenkins varreria a conta e criaria tudo sozinho, inclusive o
// que ainda nem foi escrito.
//
// `central-ia-portal` NAO esta aqui de proposito: ele nao tem Jenkinsfile, e
// quem constroi o portal e o pipeline do `central-ia`, que o busca. Dois
// pipelines editando o mesmo overlay brigariam.
// ---------------------------------------------------------------------------
def REPOS = [
    'system-api', 'sigma-midia', 'central-ia', 'opuschat', 'cafe-mobile-erp',
    'sigma-financeiro', 'live-flow', 'sigma-payments', 'sprinklegames-portal',
    'gateway',
]

def jenkins = Jenkins.get()
def criados = 0
def mantidos = 0

REPOS.each { repo ->
    // 🐞 NAO apagar e recriar.
    //
    // A primeira versao fazia `existente.delete()` antes de criar. Como este
    // script roda em TODA partida do Jenkins, cada reinicio apagaria o
    // historico de builds de todos os dez projetos -- e o historico e
    // justamente o que responde "quando isso parou de funcionar?".
    //
    // Job que ja existe fica de pe; so a configuracao e reafirmada.
    def projeto = jenkins.getItem(repo)
    if (projeto == null) {
        projeto = jenkins.createProject(WorkflowMultiBranchProject, repo)
        criados++
    } else {
        mantidos++
    }

    def fonte = new GitSCMSource("git@github.com:Samucation/${repo}.git")
    fonte.setCredentialsId(ID_CRED)

    // ⚠️ So `main`. Sem este filtro o Jenkins constroi TODA branch que tenha
    // Jenkinsfile -- e cada branch de trabalho viraria build. Os proprios
    // Jenkinsfile ja travam o DEPLOY na main, mas construir tudo desperdicaria
    // o disco de 57G que ja esta em 76%.
    fonte.setTraits([new RegexSCMHeadFilterTrait('^main$')])

    projeto.setSourcesList([new BranchSource(fonte)])
    projeto.setDescription(
        "Esteira de ${repo}. Descoberta por SSH (lista a mao) -- ver a divida " +
        "de seguranca em vm/jenkins-ssh-e-jobs.groovy")

    // ⚠️ Sem gatilho periodico o job NUNCA reprocura branches sozinho.
    //
    // A pasta de organizacao tinha varredura embutida; um Multibranch solto
    // nao tem. Sem isto, um `git push` nao viraria build nunca -- o job ficaria
    // parado parecendo saudavel, que e o pior tipo de quebra.
    //
    // 1 hora, e nao menos: quem varre e o GitHub do outro lado, e nao ha
    // webhook (esta maquina esta atras de NAT e o GitHub nao a alcanca).
    if (!projeto.getTriggers().values().any { it instanceof PeriodicFolderTrigger }) {
        projeto.addTrigger(new PeriodicFolderTrigger('1h'))
    }

    projeto.save()
}

// ---------------------------------------------------------------------------
// 3. DISPARAR A VARREDURA -- e NAO aqui em cima.
//
// 🐞 Criar o job nao o indexa: um Multibranch novo fica com ZERO branches ate
// alguem mandar varrer (na tela, o botao "Scan Repository Now").
//
// 🐞 E chamar `scheduleBuild2(0)` no meio do laco acima NAO funciona. Este
// script roda DURANTE a partida do Jenkins, antes de o escalonador estar de
// pe, e a ordem e simplesmente descartada -- sem erro, sem log. Foi medido:
// dez jobs criados, `queue.xml` vazio, zero branches, e os dez jobs parecendo
// saudaveis. A impressao era de que a credencial SSH tinha falhado; ela estava
// perfeita.
//
// Entao a varredura sai numa linha de execucao separada, que espera o Jenkins
// terminar de subir. `setDaemon` para nao segurar o desligamento.
// ---------------------------------------------------------------------------
def disparo = new Thread({
    sleep(90000)
    def n = 0
    REPOS.each { repo ->
        def p = Jenkins.get().getItem(repo)
        if (p != null) { p.scheduleBuild2(0); n++ }
    }
    println "[ssh] varredura disparada em ${n} job(s), 90s apos a partida"
})
disparo.setDaemon(true)
disparo.start()

println "[ssh] ${criados} job(s) criados, ${mantidos} mantidos; varredura agendada para daqui a 90s"

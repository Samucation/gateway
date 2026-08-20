/*
 * ===========================================================================
 * Cria no Jenkins o job "vigia-backups", SEM abrir a tela.
 *
 * Instalar em: /var/lib/jenkins/init.groovy.d/jenkins-vigia-backups.groovy
 * Depois:      sudo systemctl restart jenkins
 *
 * ---------------------------------------------------------------------------
 * POR QUE OS BACKUPS *NAO* VIRARAM JOBS DO JENKINS
 * ---------------------------------------------------------------------------
 * O pedido era acompanhar os backups pelo Jenkins. O caminho obvio seria mover
 * os 9 CronJobs para ca -- e seria um erro.
 *
 * Isso acoplaria a seguranca dos DADOS a disponibilidade do CI. Jenkins
 * reiniciando, atualizando ou quebrado numa madrugada viraria noite sem
 * backup, e ninguem olha CI de madrugada. O CronJob do Kubernetes roda dentro
 * do cluster, ao lado do banco, e nao depende de nada disto estar de pe.
 *
 * Entao a execucao fica onde esta, e o Jenkins ganha o que faltava: um lugar
 * onde da para VER. Este job nao faz backup -- ele CONFERE, e fica vermelho
 * quando algo nao rodou.
 *
 * ---------------------------------------------------------------------------
 * ⚠️ ELE E DEFINIDO AQUI DENTRO, e nao lido de um repositorio
 * ---------------------------------------------------------------------------
 * A pasta de organizacao cria um job por REPOSITORIO, a partir do `Jenkinsfile`
 * da raiz. Este vigia nao pertence a repositorio nenhum -- ele olha o cluster
 * inteiro.
 *
 * Definido aqui, ele tambem nao depende do token do GitHub: existe assim que o
 * Jenkins sobe, mesmo antes de qualquer esteira ter sido descoberta.
 * ===========================================================================
 */
import jenkins.model.Jenkins
import org.jenkinsci.plugins.workflow.job.WorkflowJob
import org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition
import hudson.triggers.TimerTrigger

def NOME = 'vigia-backups'

// ⚠️ O pipeline so CHAMA o script. A logica mora em vm/conferir-backups.sh,
// instalado em /usr/local/bin.
//
// 🐞 A primeira versao trazia o shell inteiro aqui dentro, num bloco `"""` do
// Groovy onde cada `$` e cada `\` precisava de escape duplo. Foi exatamente
// ali que nasceu um defeito que passou por VERDE: o `tr -s ' ' '|'` quebrava
// TAMBEM os espacos da agenda do cron (`0 3 * * *`), e o campo lido como
// "ultima execucao" era o campo HORA. O `date -d "3"` devolvia 3h da manha de
// hoje, a idade saia plausivel, e o vigia reportava "em dia" sem nunca ter
// olhado a data real.
//
// Um alarme que nao alarma e pior que nenhum, porque cria confianca. Com a
// logica num arquivo proprio da para executa-la na VM e VER a saida -- que foi
// como o defeito apareceu.
def SCRIPT = '''
pipeline {
    agent any
    options { timeout(time: 10, unit: 'MINUTES'); timestamps() }
    triggers { cron('0 8 * * *') }

    stages {
        stage('Conferir os backups') {
            steps {
                sh '/usr/local/bin/conferir-backups.sh'
            }
        }
    }

    post {
        failure {
            echo 'Backup atrasado ou ausente. A coluna ESTADO da tabela diz qual.'
        }
    }
}
'''

def jenkins = Jenkins.get()
def existente = jenkins.getItem(NOME)

// Recriar em vez de atualizar: o job e definido por este arquivo, entao o que
// esta no disco tem que perder para o que esta aqui. Sem isto, editar o script
// nao teria efeito nenhum e ninguem entenderia por que.
if (existente != null) {
    existente.delete()
    println "[vigia] job '${NOME}' anterior removido"
}

def job = jenkins.createProject(WorkflowJob, NOME)
job.setDefinition(new CpsFlowDefinition(SCRIPT, true))
job.setDescription(
    'Confere se os 9 CronJobs de backup do cluster rodaram nas ultimas 26h. ' +
    'NAO faz backup -- os CronJobs continuam no Kubernetes de proposito, para ' +
    'que a seguranca dos dados nao dependa do Jenkins estar de pe.')
job.addTrigger(new TimerTrigger('0 8 * * *'))
job.save()

println "[vigia] job '${NOME}' criado, diario as 08:00"

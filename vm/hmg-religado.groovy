// ===========================================================================
// Religa as etapas de HOMOLOGAÇÃO das esteiras.
//
// Roda em `init.groovy.d`, a cada partida do Jenkins.
//
// ---------------------------------------------------------------------------
// POR QUE ELAS ESTAVAM DESLIGADAS
// ---------------------------------------------------------------------------
// Em 21/08/2026, no corte, a estação virou PRODUÇÃO e o ambiente de
// homologação deixou de existir por um tempo. As esteiras continuaram
// aplicando `k8s/overlays/hmg` -- no cluster que agora era produção.
//
// O estrago: às 20:48 o Ingress do Urupix voltou de `urupix.com.br` para
// `urupix.hmg`. O domínio público passou a dar 404 com a aplicação
// perfeitamente de pé, minutos depois de alguém mexer em qualquer projeto.
//
// A guarda que nasceu dali é simples: sem `HMG_CONTEXTO` definida, as três
// etapas de homologação avisam e saem com 0. A imagem é construída, testada e
// publicada; só não é implantada em lugar nenhum.
//
// ---------------------------------------------------------------------------
// POR QUE PODE RELIGAR AGORA
// ---------------------------------------------------------------------------
// A homologação voltou a existir, e em OUTRO cluster: k3d (`k3d-hmg`), dentro
// do Docker Desktop, com 47 Pods e os 9 projetos.
//
// E o destino é outro de verdade, não o mesmo com outro nome:
//
//     produção     -> k3s da distro WSL2 `prd`   (kubeconfig padrão)
//     homologação  -> k3d no Docker Desktop      (--kubeconfig .kube/config-hmg)
//
// ⚠️ Se um dia o `config-hmg` apontar para o mesmo cluster da produção, a
// guarda perde o efeito e o estrago de 21/08 volta. Por isso este script
// CONFERE o nó do outro lado antes de religar, e recusa se for o mesmo.
// ===========================================================================
import jenkins.model.Jenkins
import hudson.slaves.EnvironmentVariablesNodeProperty

def jenkins = Jenkins.get()

// ---- 1. o destino de homologação é MESMO outro cluster? -------------------
def kubeconfig = "/var/lib/jenkins/.kube/config-hmg"

// ---------------------------------------------------------------------------
// ⚠️ COM LIMITE DE TEMPO -- e este script JA TRAVOU A PARTIDA DO JENKINS
// ---------------------------------------------------------------------------
// A versao anterior chamava `.execute().text` direto. Esse `.text` BLOQUEIA ate
// o processo terminar, e `init.groovy.d` roda DENTRO da partida do Jenkins:
// enquanto o comando nao volta, o Jenkins nao sobe.
//
// Em 29/08/2026, com o Docker Desktop desligado (o k3d de homologacao vive
// nele), o `kubectl` ficou pendurado esperando a rede. Resultado medido:
//
//   systemd:  "Job for jenkins.service failed because a timeout was exceeded"
//   HTTP:     503 por mais de 12 minutos
//   ps:       um `kubectl` do usuario jenkins parado desde a partida
//
// O Jenkins so voltou depois de alguem matar o processo a mao. Ou seja: um
// cluster de HOMOLOGACAO fora do ar derrubava a ferramenta que constroi
// PRODUCAO -- e o sintoma ("timeout do systemd") nao aponta para ca em momento
// nenhum.
//
// ⚠️ O `--request-timeout` do proprio kubectl NAO basta: ele limita a chamada
// HTTP, e nao a resolucao de nome nem o aperto de mao TLS, que e onde este caso
// travou. Por isso o teto e' externo, com `timeout(1)` do shell, e ainda ha um
// `waitForOrKill` como segunda rede.
def perguntaAoCluster = { List<String> cmd ->
    try {
        def p = (["timeout", "10"] + cmd).execute()
        def saida = new StringBuffer()
        def erro = new StringBuffer()
        p.consumeProcessOutput(saida, erro)
        p.waitForOrKill(12000)
        return saida.toString().trim()
    } catch (e) {
        println "hmg-religado: nao consegui consultar o cluster (${e.message})"
        return ""
    }
}

def noHmg = perguntaAoCluster(["kubectl", "--kubeconfig=${kubeconfig}", "get", "nodes",
                               "-o", "jsonpath={.items[0].metadata.name}"])
def noPrd = perguntaAoCluster(["kubectl", "get", "nodes",
                               "-o", "jsonpath={.items[0].metadata.name}"])

if (!noHmg) {
    println "hmg-religado: o cluster de homologacao nao respondeu -- NAO religando."
    println "              (Docker Desktop desligado? k3d parado?)"
    return
}
if (noHmg == noPrd) {
    println "hmg-religado: RECUSANDO -- o kubeconfig de hmg aponta para o mesmo no"
    println "              da producao (${noHmg}). Religar aqui desfaria producao a"
    println "              cada build, como em 21/08/2026."
    return
}

// ---- 2. religa --------------------------------------------------------------
def globais = jenkins.getGlobalNodeProperties()
def prop = globais.get(EnvironmentVariablesNodeProperty)
if (prop == null) {
    prop = new EnvironmentVariablesNodeProperty()
    globais.add(prop)
}
def vars = prop.getEnvVars()

// O valor em si só precisa ser não-vazio: quem escolhe o cluster é o
// `--kubeconfig` do KUBECTL_HMG. Guardar o nome do nó deixa o log honesto sobre
// PARA ONDE a homologação está indo.
vars.put("HMG_CONTEXTO", "k3d-hmg (${noHmg})")
vars.put("HMG_ENTRADA", "http://192.168.15.9:8090")

// O registro da HOMOLOGAÇÃO, que é outro e precisa ser.
//
// 🐞 O registro da produção vive DENTRO da distro WSL2, e contêiner do Docker
// não tem rota até lá -- medido: de um contêiner, `ping` na distro perde 100%
// dos pacotes e a porta nem responde. O k3d nunca conseguiria baixar de lá.
//
// ⚠️ E isso não aparecia: os Pods de hmg seguiam no ar com as imagens que já
// estavam no nó. O defeito só surgiria na próxima implantação -- que também
// não acontecia, porque as etapas de homologação estavam desligadas. Um
// defeito escondido atrás do outro.
//
// O ponto de encontro entre as duas distros é uma porta publicada pelo Docker
// no host Windows: o registro de hmg está na 32001, com os dados em `G:`
// (o `C:` já chegou a 0 GB nesta máquina).
vars.put("REGISTRO_HMG", "192.168.15.9:32001")

jenkins.save()
println "hmg-religado: homologacao LIGADA -> ${noHmg} (producao segue em ${noPrd})"

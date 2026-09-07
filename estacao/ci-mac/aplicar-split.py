# -*- coding: utf-8 -*-
"""
Aplica a divisao CI/CD num Jenkinsfile JA EXISTENTE, sem regenerar.

    python aplicar-split.py <caminho do Jenkinsfile>

-------------------------------------------------------------------------------
POR QUE ESTE ARQUIVO EXISTE
-------------------------------------------------------------------------------
🐞 `live-flow` e `opuschat` tem correcoes feitas A MAO que o gerador NAO
conhece -- e o proprio `gerar-jenkinsfiles.py` avisa disso no cabecalho:

    live-flow  ->  PROMOVER_AUTO + catch (FlowInterruptedException)
    opuschat   ->  promocao direta (pipeline-direct-prd)

Em 07/09/2026 eu regenerei os oito e APAGUEI as duas. Duas vezes: consertei a
mao, regenerei de novo, e apaguei de novo. O aviso estava escrito no arquivo
que eu executei.

⚠️ Entao estes dois NAO passam pelo gerador ate' que as correcoes subam para o
molde. Este script faz a mesma transformacao por texto, preservando o resto.

⚠️ E ele e' IDEMPOTENTE: rodar duas vezes nao duplica nada.
"""
import io
import sys

def aplicar(caminho):
    s = io.open(caminho, encoding='utf-8').read()

    if "stage('CI')" in s:
        print('  ja tem a divisao -- nada a fazer')
        return False

    # 1) agent none
    alvo = "pipeline {\n    agent any\n"
    if alvo not in s:
        print('  NAO achei `agent any` no topo -- revisar a mao')
        return False
    s = s.replace(alvo, """pipeline {
    // ⚠️ `agent none`: esta esteira roda em DOIS lugares. Construir e testar
    // podem sair da maquina de producao; implantar NAO pode.
    agent none
""", 1)

    # 2) o parametro AGENTE_CI
    #
    # 🐞 `live-flow` JA TEM um bloco `parameters` (o `PROMOVER_AUTO`), e
    # acrescentar outro faz o Jenkins recusar o arquivo inteiro:
    #
    #     Multiple occurrences of the parameters section
    #
    # Entao: se ja' existe, ENTRA DENTRO; senao, cria.
    PARAM = """        // O padrao DIVIDE o trabalho. Com o MacBook dormindo ou fora da rede,
        // a build cai no built-in e nada para -- ele segue sendo a rede de
        // seguranca.
        string(name: 'AGENTE_CI', defaultValue: 'mac-arm || built-in',
               description: "Label do agente para CONSTRUIR e TESTAR.")
"""
    if "\n    parameters {" in s:
        s = s.replace("\n    parameters {\n", "\n    parameters {\n" + PARAM, 1)
        print('  parametro inserido no bloco existente')
    else:
        s = s.replace("    agent none\n", "    agent none\n\n    parameters {\n" + PARAM + "    }\n", 1)
        print('  bloco parameters criado')

    # 2) abre CI
    s = s.replace("    stages {\n", """    stages {

    // =======================================================================
    // METADE 1 -- CI: construir e testar. PODE sair da maquina de producao.
    // =======================================================================
    stage('CI') {
        agent { label params.AGENTE_CI }

        stages {
""", 1)

    # 3) fecha CI / abre CD antes do primeiro estagio que MEXE no cluster
    for marco in ["        stage('Implantar em homologacao') {",
                  "        stage('Implantar') {"]:
        if marco in s:
            s = s.replace(marco, """        }   // fim dos estagios de CI
    }       // fim do estagio 'CI'

    // =======================================================================
    // METADE 2 -- CD: implantar. TEM de ficar na estacao.
    // =======================================================================
    // ⚠️ `built-in` EXPLICITO: de um agente remoto o `kubectl` nao falaria com
    // cluster nenhum, e o estagio morreria no meio de um deploy.
    stage('CD') {
        agent { label 'built-in' }

        stages {

""" + marco, 1)
            break
    else:
        print('  NAO achei o inicio do deploy -- revisar a mao')
        return False

    # 3.5) construir/publicar imagem FICAM na estacao
    #
    # 🐞 Nestes dois projetos os estagios de imagem ficam ENTRE os testes
    # (Preparo -> Construir -> Sonar -> Portao -> Publicar), entao nao da'
    # para separa-los por um pai `IMAGEM` sem reordenar -- e reordenar
    # arquivo com correcao feita a mao e' pedir para perder alguma.
    #
    # A saida e' fixar o agente EM CADA UM. Vale porque estes dois tem UMA
    # imagem so', sem `parallel` -- e o Jenkins recusa `agent` em estagio que
    # contem `parallel`.
    #
    # ⚠️ Sem isto, `docker build` iria para o Mac (arm64) e cairia na
    # emulacao, que em 07/09/2026 derrubou o daemon do Docker de la' duas
    # vezes, apos 103 e 88 minutos.
    for est in ("        stage('Construir') {\n", "        stage('Publicar') {\n"):
        if est in s:
            s = s.replace(est, est + "            // imagem NAO sai da estacao: no Mac isto seria emulado.\n"
                                     "            agent { label 'built-in' }\n", 1)

    # 4) fecha CD antes do post
    alvo_post = "\n    post {"
    i = s.rindex(alvo_post)
    s = s[:i] + """
        }   // fim dos estagios de CD
    }       // fim do estagio 'CD'
""" + s[i:]

    # 5) plataforma declarada nos builds de imagem
    s = s.replace('docker build ', 'docker build --platform "${PLATAFORMA:-linux/amd64}" ')
    s = s.replace('docker build --platform "${PLATAFORMA:-linux/amd64}" --platform', 'docker build --platform')

    io.open(caminho, 'w', encoding='utf-8').write(s)
    print('  divisao aplicada')
    return True

if __name__ == '__main__':
    aplicar(sys.argv[1])

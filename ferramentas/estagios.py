# -*- coding: utf-8 -*-
"""
Os moldes de estagio usados por `gerar-jenkinsfiles.py`.

-------------------------------------------------------------------------------
🐞 A REGRA DE DELIMITADOR, QUE JA CUSTOU TRES ERROS NESTE MESMO DIA
-------------------------------------------------------------------------------
Estes moldes sao strings de Python que CONTEM strings de Groovy. Se os dois
usarem o mesmo delimitador, o de dentro fecha o de fora -- e o erro aparece
dezenas de linhas adiante, apontando para um lugar sem relacao com a causa.

Aconteceu tres vezes:

  1. No Jenkinsfile do system-api, um COMENTARIO escrevia tres aspas simples
     para explicar o problema. Elas fecharam o bloco. Build #1 morreu com
     "expecting '}', found 'do'" dentro de um comentario.
  2. Aqui, montando este arquivo por shell: o `sh` com tres aspas simples do
     Groovy fechou a string de Python.
  3. Aqui de novo, ao trocar o Groovy para tres aspas DUPLAS -- que era
     exatamente o delimitador da string de Python.

A regra que vale:

    PYTHON usa tres aspas DUPLAS.   GROOVY usa tres aspas SIMPLES.

E aspas simples triplas no Groovy nao interpolam, o que traz dois beneficios:
nenhuma variavel do Groovy vaza para o shell por engano, e NAO E PRECISO
CONTRABARRA -- que no Groovy seria erro de interpretacao, e o pipeline nem
chegaria a rodar.

⚠️ Sem contrabarra tambem significa SEM QUEBRA DE LINHA em comando de shell. Os
`docker run` abaixo sao linhas longas de proposito.
"""

# ---------------------------------------------------------------------------
# SONAR -- generico (Node e Dart)
#
# ⚠️ DART NAO E ANALISADO como linguagem. Medido em 21/08/2026 perguntando ao
# proprio Sonar (`api/languages/list`): java, js, ts, go, py, kotlin, php... e
# nao `dart`.
#
# Os projetos Dart entram assim mesmo porque a lista TAMBEM traz `docker`,
# `kubernetes`, `yaml` e -- o que mais importa -- `secrets`, que procura
# credencial escrita no codigo. Nesses tres o retorno nao e "code smell": e
# achar segredo vazado.
# ---------------------------------------------------------------------------
SONAR_GENERICO = """
        // Analise estatica.
        //
        // ⚠️ Sem o plugin do Sonar, de proposito. O `waitForQualityGate` dele
        // depende de WEBHOOK -- o Sonar teria que CHAMAR o Jenkins de volta. O
        // Sonar roda dentro do cluster e o Jenkins escuta so em 127.0.0.1 do
        // host; no dia em que a rede do cluster mudar, aquilo ficaria pendurado
        // ate o tempo limite sem dizer por que. Aqui a esteira PERGUNTA.
        stage('Analisar (Sonar)') {
            steps {
                withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
                    sh '''
                        set -e
                        # ⚠️ --add-host: o conteiner do scanner tem /etc/hosts
                        # PROPRIO, entao `sonar.hmg` nao resolve nele nem com
                        # --network host. Sem isto o erro fala de DNS e manda a
                        # pessoa procurar problema de rede que nao existe.
                        #
                        # ⚠️ Linha longa de proposito: contrabarra dentro deste
                        # bloco e erro de interpretacao do Groovy.
                        EXC="**/node_modules/**,**/target/**,**/build/**,**/dist/**,**/.dart_tool/**"
                        docker run --rm --network host --add-host sonar.hmg:127.0.0.1 -v "$PWD:/usr/src" -e SONAR_HOST_URL=$SONAR_URL -e SONAR_TOKEN=$SONAR_TOKEN sonarsource/sonar-scanner-cli:latest -Dsonar.projectKey=$SONAR_CHAVE -Dsonar.projectName=$SONAR_CHAVE -Dsonar.sources=. -Dsonar.exclusions="$EXC" -Dsonar.scm.disabled=true
                    '''
                }
            }
        }
"""

# ---------------------------------------------------------------------------
# SONAR -- Maven (Java)
#
# ⚠️ O sensor de Java EXIGE as classes compiladas e recusa analisar so o fonte
# ("Please provide compiled classes of your project with sonar.java.binaries").
# Por isso os projetos Maven rodam o scanner DENTRO de uma imagem do Maven, que
# compila e analisa no mesmo passo.
#
# ⚠️ CUSTO DE DISCO: a imagem do Maven (~500 MB) mais o cache de dependencias
# num volume nomeado. O disco desta VM ja esteve em 98% -- se apertar de novo,
# `docker volume rm jenkins-m2` devolve o cache, ao custo de rebaixar tudo no
# proximo build.
# ---------------------------------------------------------------------------
SONAR_MAVEN = """
        // ⚠️ Maven, e nao o scanner generico: o sensor de Java exige CLASSES
        // COMPILADAS. A imagem compila e analisa no mesmo passo, e o cache de
        // dependencias fica num volume nomeado para nao rebaixar tudo sempre.
        stage('Analisar (Sonar)') {
            steps {
                withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
                    sh '''
                        set -e
                        docker run --rm --network host --add-host sonar.hmg:127.0.0.1 -v "$PWD:/app" -w /app -v jenkins-m2:/root/.m2 maven:3.9-eclipse-temurin-21 mvn -B -DskipTests compile org.sonarsource.scanner.maven:sonar-maven-plugin:sonar -Dsonar.host.url=$SONAR_URL -Dsonar.token=$SONAR_TOKEN -Dsonar.projectKey=$SONAR_CHAVE
                    '''
                }
            }
        }
"""

# ---------------------------------------------------------------------------
# O PORTAO DE QUALIDADE
#
# ⚠️ A analise e ASSINCRONA: o scanner entrega os dados e vai embora, e o Sonar
# processa depois. Perguntar o resultado antes de a tarefa terminar devolve o
# resultado ANTERIOR -- verde de ontem num codigo que quebrou hoje.
#
# Por isso sao duas perguntas, nesta ordem: espera a tarefa terminar, DEPOIS le
# o portao.
# ---------------------------------------------------------------------------
PORTAO = """
        stage('Portao de qualidade') {
            steps {
                withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
                    sh '''
                        set -e
                        # 1. ESPERAR a analise terminar de ser processada.
                        #    Perguntar antes devolve o resultado ANTERIOR.
                        for i in $(seq 1 60); do
                            # ⚠️ `grep -oE` direto no JSON, sem `tr` para quebrar
                            # linha: `tr "," "n"` precisaria de contrabarra, e
                            # contrabarra aqui dentro e erro de interpretacao do
                            # Groovy -- o pipeline nem chegaria a rodar.
                            st=$(curl -s -u "$SONAR_TOKEN:" -H "Host: sonar.hmg" "http://127.0.0.1/api/ce/component?component=$SONAR_CHAVE" | grep -oE "SUCCESS|FAILED|CANCELED|PENDING|IN_PROGRESS" | head -1)
                            case "$st" in
                                SUCCESS|"") break ;;
                                FAILED|CANCELED) echo "a analise FALHOU no Sonar"; exit 1 ;;
                            esac
                            sleep 5
                        done

                        # 2. So AGORA ler o portao.
                        corpo=$(curl -s -u "$SONAR_TOKEN:" -H "Host: sonar.hmg" "http://127.0.0.1/api/qualitygates/project_status?projectKey=$SONAR_CHAVE")
                        r=OK
                        echo "$corpo" | grep -q "ERROR" && r=ERROR
                        echo "==> portao de qualidade: $r"
                        echo "    detalhes em $SONAR_URL/dashboard?id=$SONAR_CHAVE"

                        # ⚠️ ERROR reprova o build. Portao que so avisa e portao
                        # que ninguem fecha.
                        [ "$r" != "ERROR" ] || { echo "REPROVADO pelo portao de qualidade"; exit 1; }
                    '''
                }
            }
        }
"""

# ---------------------------------------------------------------------------
# A PROMOCAO PARA PRODUCAO
#
# ⚠️ `agent none` no estagio do `input`. Sem isso a espera SEGURA um executor --
# e sao dois nesta maquina. Duas esteiras paradas esperando aprovacao
# bloqueariam todas as outras, e a fila ficaria parada sem motivo visivel.
#
# ⚠️ E o PRD ainda nao existe. O estagio aparece no grafico e FALHA com mensagem
# clara, em vez de passar calado dando a impressao de que promoveu alguma coisa.
# ---------------------------------------------------------------------------
PROMOCAO = """
        stage('Promover para producao?') {
            when { branch 'main' }
            // ⚠️ `agent none`: a espera NAO pode segurar um executor. Sao dois
            // nesta maquina -- duas esteiras aguardando aprovacao bloqueariam
            // todas as demais, e a fila pararia sem motivo visivel.
            agent none
            options { timeout(time: 60, unit: 'MINUTES') }
            steps {
                script {
                    def r = input(
                        message: "Homologacao passou. Promover ${env.TAG} para producao?",
                        ok: 'Promover',
                        submitterParameter: 'quem',
                        parameters: [choice(name: 'ACAO', choices: ['Promover', 'Descartar'],
                                            description: 'Descartar encerra a esteira sem promover.')])
                    env.QUEM_APROVOU  = r['quem']
                    env.ACAO_PROMOCAO = r['ACAO']
                    echo "==> ${env.ACAO_PROMOCAO} decidido por ${env.QUEM_APROVOU}"
                }
            }
        }

        stage('Implantar em producao') {
            when {
                allOf {
                    branch 'main'
                    expression { env.ACAO_PROMOCAO == 'Promover' }
                }
            }
            steps {
                sh '''
                    set -e
                    if [ -z "$PRD_CONTEXTO" ]; then
                        echo "======================================================"
                        echo " PRODUCAO AINDA NAO EXISTE -- nada foi promovido."
                        echo "======================================================"
                        echo
                        echo " Este cluster E o de homologacao: todo hostname termina"
                        echo " em .hmg, e as aplicacoes recusam subir se o ambiente"
                        echo " declarado nao bater com a URL que elas usam. A producao"
                        echo " de verdade ainda roda no Docker da estacao."
                        echo
                        echo " O bloqueio real e a MIGRACAO DE DADOS: os bancos deste"
                        echo " cluster estao vazios. Promover para ca mandaria o"
                        echo " urupix.com.br para um banco sem doacao nenhuma."
                        echo
                        echo " Quando a inversao acontecer, definir PRD_CONTEXTO no"
                        echo " ambiente do pipeline e este estagio passa a funcionar."
                        exit 1
                    fi

                    K=k8s/overlays/prd/kustomization.yaml
                    A='"'
                    sed -i "s|newTag: .*|newTag: ${A}${TAG}${A}|" "$K"
                    $KUBECTL --context "$PRD_CONTEXTO" apply -k k8s/overlays/prd
                '''
            }
        }
"""

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
# ---------------------------------------------------------------------------
# TESTES COM COBERTURA (projetos Node)
#
# ⚠️ Isto e o que faz o portao de qualidade MEDIR alguma coisa.
#
# Sem relatorio de cobertura o Sonar assume 0%, e o portao padrao -- que exige
# 80% em codigo NOVO -- reprova TODO build, por melhor que o codigo esteja. Foi
# exatamente o que aconteceu com o live-flow nos builds #2 a #6: `Construir`
# verde, `Portao de qualidade` vermelho, sempre.
#
# ⚠️ Os testes precisam de um POSTGRES. O `tests/global-setup.ts` cria um banco
# descartavel, roda as migracoes e o apaga no fim -- ele so precisa de um
# servidor onde possa executar CREATE DATABASE. Nenhum dado real e tocado, e o
# proprio setup forca PAYOUTS_LIVE=false e REDIS_URL vazio.
#
# ⚠️ `--network host`, e NAO uma rede propria: criar rede no Docker REINICIA o
# kubelite do MicroK8s (medido: 4 segundos de cluster fora do ar). Por isso o
# Postgres sobe em porta alta no host.
# ---------------------------------------------------------------------------
TESTES_NODE = """
        stage('Testes + cobertura') {
            steps {
                sh '''
                    set -e
                    set -o pipefail

                    # Postgres DESCARTAVEL, so para esta execucao. O nome leva o
                    # numero do build para duas execucoes nunca colidirem.
                    PGC=pg-teste-$BUILD_NUMBER
                    PGP=15432

                    # 🐞 Remove TODOS os `pg-teste-*`, nao so o deste build.
                    #
                    # A primeira versao fazia `docker rm -f $PGC` -- o do build
                    # ATUAL, que nunca existe na primeira tentativa. Um build
                    # anterior que tenha morrido antes da limpeza (por falha, por
                    # aborto, por reinicio do Jenkins) deixa o conteiner de pe
                    # SEGURANDO A PORTA.
                    #
                    # Foi o que derrubou o build #8: o `pg-teste-7` continuava no
                    # ar, e o Postgres novo morreu com
                    # "could not bind IPv4 address: Address in use". A mensagem
                    # aparecia no `docker logs`, nao no erro do passo -- entao
                    # sem o dump de log que este estagio faz, o sintoma seria
                    # apenas "nao subiu em 60 segundos".
                    for velho in $(docker ps -aq --filter name=pg-teste 2>/dev/null); do
                        docker rm -f "$velho" >/dev/null 2>&1 || true
                    done

                    # ⚠️ Porta pela linha de comando do Postgres, porque com
                    # --network host o -p do Docker nao vale.
                    docker run -d --name $PGC --network host -e POSTGRES_USER=teste -e POSTGRES_PASSWORD=teste -e POSTGRES_DB=postgres postgres:16-alpine -c port=$PGP >/dev/null

                    # `pg_isready`, e nao porta TCP: a porta abre ANTES de o
                    # Postgres aceitar conexao, e quem conectasse no intervalo
                    # tomaria erro num servidor ja dado como pronto.
                    pronto=0
                    for i in $(seq 1 30); do
                        if docker exec $PGC pg_isready -U teste -p $PGP >/dev/null 2>&1; then pronto=1; break; fi
                        sleep 2
                    done
                    if [ "$pronto" != "1" ]; then
                        echo "ERRO: o Postgres de teste nao subiu em 60 segundos"
                        docker logs $PGC 2>&1 | tail -10
                        docker rm -f $PGC >/dev/null 2>&1 || true
                        exit 1
                    fi

                    # ⚠️ Nada de `|| true` aqui: teste que falha TEM que reprovar
                    # o build.
                    #
                    # O conteiner e removido tambem no `post { always }`, que
                    # roda mesmo quando este passo morre -- e ESSA e a rede de
                    # seguranca que faltava: sem ela, um build interrompido aqui
                    # deixava o Postgres de pe e o build SEGUINTE nao conseguia
                    # subir o dele.
                    npm ci --no-audit --no-fund --ignore-scripts

                    # 🐞 `prisma generate` EXPLICITO, por causa do
                    # `--ignore-scripts`.
                    #
                    # O cliente do Prisma e codigo GERADO, e quem o gera e um
                    # script de pos-instalacao -- exatamente o que
                    # `--ignore-scripts` pula. (E o `--ignore-scripts` existe
                    # porque o npm 11 exige aprovacao interativa para esses
                    # scripts, e dentro da esteira nao ha ninguem para aprovar.)
                    #
                    # Sem esta linha, 52 dos 102 arquivos de teste morrem no
                    # import com "Cannot find package '@/generated/prisma/client'"
                    # -- e o sintoma engana: parece teste quebrado, e e biblioteca
                    # ausente. Na maquina de quem desenvolve nao aparece, porque
                    # o cliente ja foi gerado alguma vez.
                    #
                    # ⚠️ O DATABASE_URL aqui e so para a configuracao do Prisma
                    # carregar; `generate` le o ESQUEMA e nunca abre conexao.
                    DATABASE_URL="postgresql://teste:teste@127.0.0.1:$PGP/postgres" npx prisma generate

                    # ⚠️ Segredos DE TESTE, gerados agora e jogados fora depois.
                    #
                    # 🐞 13 arquivos de teste morriam com "TOKEN_ENCRYPTION_KEY
                    # ausente/invalida no .env". As aplicacoes recusam subir sem
                    # eles -- e isso e correto -- mas na esteira nao ha `.env`.
                    #
                    # Gerados A CADA EXECUCAO, e nao fixos no repositorio: os
                    # testes cifram e decifram dentro da mesma execucao, entao
                    # qualquer valor valido serve. Chave fixa versionada pareceria
                    # segredo de verdade, e alguem acabaria reusando em outro
                    # lugar -- que e como um valor de teste vira credencial de
                    # producao sem ninguem decidir isso.
                    export TOKEN_ENCRYPTION_KEY=$(openssl rand -hex 32)
                    export APP_AUTH_SECRET=$(openssl rand -hex 32)
                    export AUTH_SECRET=$APP_AUTH_SECRET

                    DATABASE_URL="postgresql://teste:teste@127.0.0.1:$PGP/postgres" npx vitest run --coverage

                    docker rm -f $PGC >/dev/null 2>&1 || true
                    echo "==> cobertura gerada em coverage/lcov.info"
                '''
            }
        }
"""

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
                        # ⚠️ `pipefail`: sem ele, o `| tee` mais abaixo faz o
                        # `set -e` enxergar o codigo do TEE, que sempre da certo.
                        # Um scanner que falhasse passaria por sucesso.
                        set -o pipefail
                        # ⚠️ --add-host: o conteiner do scanner tem /etc/hosts
                        # PROPRIO, entao `sonar.hmg` nao resolve nele nem com
                        # --network host. Sem isto o erro fala de DNS e manda a
                        # pessoa procurar problema de rede que nao existe.
                        #
                        # ⚠️ Linha longa de proposito: contrabarra dentro deste
                        # bloco e erro de interpretacao do Groovy.
                        EXC="**/node_modules/**,**/target/**,**/build/**,**/dist/**,**/.dart_tool/**"
                        # ⚠️ A saida do scanner e CAPTURADA, e o id da tarefa
                        # sai dela -- nao do `.scannerwork/report-task.txt`.
                        #
                        # 🐞 O arquivo NAO aparece no espaco de trabalho: ele e
                        # `drwxr-xr-x jenkins`, e o conteiner do scanner roda com
                        # outro usuario. A analise funciona (ela sobe por HTTP),
                        # mas o relatorio local nao pode ser gravado, e some com
                        # o conteiner. O portao entao reprovava por falta de um
                        # arquivo que nunca teria como existir.
                        #
                        # O proprio scanner imprime a URL da tarefa; ler dali nao
                        # depende de permissao nenhuma.
                        docker run --rm --network host --add-host sonar.hmg:127.0.0.1 -v "$PWD:/usr/src" -e SONAR_HOST_URL=$SONAR_URL -e SONAR_TOKEN=$SONAR_TOKEN sonarsource/sonar-scanner-cli:latest -Dsonar.projectKey=$SONAR_CHAVE -Dsonar.projectName=$SONAR_CHAVE -Dsonar.sources=. -Dsonar.exclusions="$EXC" -Dsonar.scm.disabled=true -Dsonar.javascript.lcov.reportPaths=coverage/lcov.info 2>&1 | tee saida-sonar.txt
                        grep -oE "api/ce/task[?]id=[A-Za-z0-9_-]+" saida-sonar.txt | tail -1 | cut -d= -f2 > sonar-task.txt
                        echo "==> tarefa: $(cat sonar-task.txt)"
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
                        # ⚠️ `pipefail`: sem ele, o `| tee` mais abaixo faz o
                        # `set -e` enxergar o codigo do TEE, que sempre da certo.
                        # Um scanner que falhasse passaria por sucesso.
                        set -o pipefail
                        # ⚠️ A saida do scanner e CAPTURADA, e o id da tarefa
                        # sai dela -- nao do `.scannerwork/report-task.txt`.
                        #
                        # 🐞 O arquivo NAO aparece no espaco de trabalho: ele e
                        # `drwxr-xr-x jenkins`, e o conteiner do scanner roda com
                        # outro usuario. A analise funciona (ela sobe por HTTP),
                        # mas o relatorio local nao pode ser gravado, e some com
                        # o conteiner. O portao entao reprovava por falta de um
                        # arquivo que nunca teria como existir.
                        #
                        # O proprio scanner imprime a URL da tarefa; ler dali nao
                        # depende de permissao nenhuma.
                        docker run --rm --network host --add-host sonar.hmg:127.0.0.1 -v "$PWD:/app" -w /app -v jenkins-m2:/root/.m2 maven:3.9-eclipse-temurin-21 mvn -B -DskipTests compile org.sonarsource.scanner.maven:sonar-maven-plugin:sonar -Dsonar.host.url=$SONAR_URL -Dsonar.token=$SONAR_TOKEN -Dsonar.projectKey=$SONAR_CHAVE 2>&1 | tee saida-sonar.txt
                        grep -oE "api/ce/task[?]id=[A-Za-z0-9_-]+" saida-sonar.txt | tail -1 | cut -d= -f2 > sonar-task.txt
                        echo "==> tarefa: $(cat sonar-task.txt)"
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
                        # ⚠️ `pipefail`: sem ele, o `| tee` mais abaixo faz o
                        # `set -e` enxergar o codigo do TEE, que sempre da certo.
                        # Um scanner que falhasse passaria por sucesso.
                        set -o pipefail

                        # ================================================================
                        # 🐞 ESTE PORTAO JA FOI FAIL-OPEN, E PASSOU EM 0 SEGUNDOS
                        # ================================================================
                        # A primeira versao consultava `api/ce/component` para
                        # saber se a analise terminara. Esse endpoint devolve
                        # "Insufficient privileges" para um token de ANALISE --
                        # entao a variavel vinha vazia, o laco saia na primeira
                        # volta, e um padrao `r=OK` fazia o portao APROVAR.
                        #
                        # Passou verde sem ter perguntado nada. Um portao que
                        # aprova quando nao consegue consultar e pior que nao ter
                        # portao: da confianca sem dar garantia.
                        #
                        # Agora: qualquer duvida REPROVA, e o caminho de espera
                        # usa o report-task.txt que o proprio scanner escreve --
                        # que o token de analise PODE ler.
                        # ================================================================

                        # O id vem da SAIDA do scanner, capturada no estagio
                        # anterior. Ver a nota la sobre por que nao e o
                        # `.scannerwork/report-task.txt`.
                        if [ ! -s sonar-task.txt ]; then
                            echo "ERRO: sonar-task.txt vazio -- a analise nao chegou a rodar."
                            exit 1
                        fi
                        TAREFA=$(cat sonar-task.txt)
                        [ -n "$TAREFA" ] || { echo "ERRO: sem id de tarefa"; exit 1; }
                        echo "==> tarefa de analise: $TAREFA"

                        # 1. ESPERAR a analise ser PROCESSADA.
                        #    Perguntar o portao antes disso devolveria o resultado
                        #    ANTERIOR -- verde de ontem num codigo que quebrou hoje.
                        st=""
                        for i in $(seq 1 60); do
                            st=$(curl -s -u "$SONAR_TOKEN:" -H "Host: sonar.hmg" "http://127.0.0.1/api/ce/task?id=$TAREFA" | grep -oE "PENDING|IN_PROGRESS|SUCCESS|FAILED|CANCELED" | head -1)
                            case "$st" in
                                SUCCESS)         break ;;
                                FAILED|CANCELED) echo "a analise FALHOU no Sonar (estado $st)"; exit 1 ;;
                            esac
                            sleep 5
                        done
                        if [ "$st" != "SUCCESS" ]; then
                            echo "ERRO: a analise nao terminou em 5 minutos (ultimo estado: ${st:-desconhecido})"
                            exit 1
                        fi

                        # 2. So AGORA ler o portao.
                        corpo=$(curl -s -u "$SONAR_TOKEN:" -H "Host: sonar.hmg" "http://127.0.0.1/api/qualitygates/project_status?projectKey=$SONAR_CHAVE")
                        r=$(echo "$corpo" | grep -oE "OK|ERROR|WARN|NONE" | head -1)
                        echo "==> portao de qualidade: ${r:-SEM RESPOSTA}"
                        echo "    detalhes em $SONAR_URL/dashboard?id=$SONAR_CHAVE"

                        # ⚠️ FAIL-CLOSED: so `OK` passa. Vazio, erro de rede,
                        # privilegio insuficiente ou qualquer outra coisa REPROVA.
                        if [ "$r" != "OK" ]; then
                            echo "REPROVADO pelo portao de qualidade."
                            echo "$corpo" | head -c 400
                            exit 1
                        fi

                        # ⚠️ Portao sem CONDICAO nenhuma tambem e alarme falso.
                        #
                        # O portao padrao do Sonar avalia CODIGO NOVO. Na primeira
                        # analise de um projeto que ja existia nao ha base de
                        # comparacao, entao ele devolve `"conditions":[]` e aprova
                        # tudo -- inclusive um codigo cheio de problemas antigos.
                        #
                        # Isso nao reprova o build (seria injusto no primeiro
                        # build), mas fica dito ALTO no log, para ninguem
                        # confundir "passou" com "foi avaliado".
                        # `grep -qF`: busca LITERAL. Com regex seriam precisos
                        # escapes para os colchetes, e contrabarra aqui dentro e
                        # erro de interpretacao do Groovy.
                        if echo "$corpo" | grep -qF 'conditions":[]'; then
                            echo
                            echo "    ⚠️  ATENCAO: o portao passou SEM NENHUMA CONDICAO avaliada."
                            echo "        O portao padrao olha so CODIGO NOVO, e nesta analise"
                            echo "        nao havia base de comparacao. Ele NAO garantiu nada"
                            echo "        sobre o codigo existente."
                        fi
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

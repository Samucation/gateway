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
                    #
                    # ⚠️ `-v` JUNTO. A imagem do Postgres declara `VOLUME` para o
                    # diretorio de dados, entao cada `docker run` cria um volume
                    # ANONIMO. `docker rm` sem `-v` remove o conteiner e ABANDONA
                    # o volume: ~50 MB por rodada de teste que nada mais aponta.
                    #
                    # 🐞 Medido em 21/08/2026: 15 volumes orfaos, 739 MB. Eles nao
                    # aparecem em `docker ps` nem em `docker images` -- so em
                    # `docker system df`, na linha que ninguem le. Vazamento que
                    # so aparece quando o disco acaba.
                    for velho in $(docker ps -aq --filter name=pg-teste 2>/dev/null); do
                        docker rm -fv "$velho" >/dev/null 2>&1 || true
                    done

                    # 🐞 Baixa a imagem ANTES, com repeticao.
                    #
                    # O `Preparo` roda `docker image prune -af` para caber no
                    # disco -- e isso apaga o `postgres:16-alpine`, que nao esta
                    # em uso naquele momento. O `docker run` seguinte teria que
                    # baixar sozinho, e uma baixa interrompida deixa o armazem
                    # local INCONSISTENTE:
                    #
                    #     NotFound: content digest sha256:... not found
                    #
                    # Foi o que derrubou o build #15. E o erro engana: fala de
                    # digest, parece corrupcao de registro remoto, e e so estado
                    # local pela metade.
                    #
                    # Duas tentativas, e a segunda depois de apagar o resto
                    # quebrado -- que e o que conserta o caso do digest.
                    if ! docker pull postgres:16-alpine >/dev/null 2>&1; then
                        echo "==> primeira baixa falhou; limpando o estado local e tentando de novo"
                        docker image rm postgres:16-alpine >/dev/null 2>&1 || true
                        docker pull postgres:16-alpine >/dev/null 2>&1 || {
                            echo "ERRO: nao consegui baixar postgres:16-alpine"; exit 1;
                        }
                    fi

                    # ⚠️ Porta pela linha de comando do Postgres, porque com
                    # --network host o -p do Docker nao vale.
                    #
                    # ⚠️ `max_connections` bem acima do padrao (100).
                    #
                    # 🐞 Build #26: o banco caiu 30 segundos depois de subir, no
                    # quinto arquivo de 107, com "Connection terminated
                    # unexpectedly" em todo teste que usa banco. O conjunto roda
                    # com `fileParallelism: false`, mas cada arquivo abre seu
                    # proprio conjunto de conexoes -- e conexao que nao e
                    # devolvida vai somando. Passar do teto derruba as que ja
                    # existiam, e o sintoma aparece longe da causa: falha em
                    # testes que nao tem nada a ver com quem vazou a conexao.
                    #
                    # 400 nao pesa: e um banco descartavel, em memoria de
                    # sobra, que vive alguns minutos.
                    docker run -d --name $PGC --network host -e POSTGRES_USER=teste -e POSTGRES_PASSWORD=teste -e POSTGRES_DB=postgres postgres:16-alpine -c port=$PGP -c max_connections=400 >/dev/null

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
                        docker rm -fv $PGC >/dev/null 2>&1 || true
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

                    # Chaves VAPID (Web Push), para o `push-admin.ts` -- que e o
                    # canal do painel administrativo.
                    #
                    # ⚠️ NAO e o que faz `aviso-de-live` passar. Eu supus que
                    # fosse e estava errado: aquele teste usa `pushToken`, que e
                    # FCM (Firebase), tratado logo abaixo. As chaves ficam porque
                    # outros caminhos as usam, e sao baratas de gerar.
                    # ⚠️ `grep -oE` + `cut`, e nao `sed` com grupo de captura:
                    # grupo de captura precisa de contrabarra, e contrabarra
                    # aqui dentro e erro de interpretacao do Groovy.
                    VAPID=$(npx --yes web-push generate-vapid-keys --json)
                    export VAPID_PUBLIC_KEY=$(echo "$VAPID" | grep -oE '"publicKey":"[^"]+"' | cut -d'"' -f4)
                    export VAPID_PRIVATE_KEY=$(echo "$VAPID" | grep -oE '"privateKey":"[^"]+"' | cut -d'"' -f4)
                    export VAPID_SUBJECT="mailto:teste@exemplo.invalido"

                    # 🐞 FCM: ESTA e a variavel que faltava de verdade.
                    #
                    # Dois testes de `aviso-de-live` esperavam 1 entrega e
                    # recebiam 0. `src/lib/fcm.ts` devolve `null` sem
                    # FCM_SERVICE_ACCOUNT_B64, e sem FCM configurado NENHUMA
                    # NoticeDelivery e enfileirada.
                    #
                    # ⚠️ Lendo so a mensagem ("expected 1, got 0") aquilo parece
                    # regra de negocio quebrada -- e o teste protege contra push
                    # DUPLICADO, entao mexer nele seria estragar uma guarda boa.
                    # Era configuracao ausente.
                    #
                    # A conta e FALSA e gerada agora: `project_id` termina em
                    # `.invalido` de proposito, para nunca parecer credencial
                    # real. A chave RSA e de verdade so para o JSON ser valido --
                    # nenhum envio sai daqui, e se saisse iria para um projeto
                    # que nao existe.
                    export FCM_SERVICE_ACCOUNT_B64=$(node -e 'const c=require("crypto");const k=c.generateKeyPairSync("rsa",{modulusLength:2048,privateKeyEncoding:{type:"pkcs8",format:"pem"},publicKeyEncoding:{type:"spki",format:"pem"}});process.stdout.write(Buffer.from(JSON.stringify({type:"service_account",project_id:"teste-invalido",private_key_id:"teste",private_key:k.privateKey,client_email:"teste@teste-invalido.iam.gserviceaccount.com",client_id:"0",token_uri:"https://oauth2.googleapis.com/token"})).toString("base64"))')

                    # ⚠️ GUARDA A PROVA ANTES DE APAGAR O BANCO.
                    #
                    # 🐞 No build #26 o Postgres morreu no meio da execucao e
                    # levou junto a unica explicacao possivel: o conteiner era
                    # removido logo depois, com o log dentro. Sobrou o sintoma
                    # ("Connection terminated unexpectedly") sem a causa, e nao
                    # deu para decidir entre falta de memoria, teto de conexoes
                    # e queda do processo.
                    #
                    # `set -e` esta ligado, entao o `if` e necessario: sem ele o
                    # passo morreria aqui e o dump nunca rodaria.
                    if DATABASE_URL="postgresql://teste:teste@127.0.0.1:$PGP/postgres" npx vitest run --coverage; then
                        ok=1
                    else
                        ok=0
                        echo "==================== o banco de teste disse ===================="
                        docker logs $PGC 2>&1 | tail -40
                        echo "==================== estado do conteiner ======================="
                        docker inspect -f 'rodando={{.State.Running}} saiu={{.State.ExitCode}} morto-por-falta-de-memoria={{.State.OOMKilled}}' $PGC 2>&1
                        echo "==================== memoria da maquina ========================"
                        free -h
                        echo "==============================================================="
                    fi

                    docker rm -fv $PGC >/dev/null 2>&1 || true
                    [ "$ok" = "1" ] || exit 1
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
                        # 🐞 E o `-Dsonar.scm.disabled=true` SAIU daqui.
                        #
                        # Com ele o Sonar nao consegue saber o que mudou, e passa
                        # a tratar o repositorio INTEIRO como codigo novo. Medido
                        # no build #18: `new_violations` = 37.548, quando o
                        # commit mexia em um arquivo.
                        #
                        # ⚠️ Isso destroi a ideia toda do portao. Ele foi
                        # desenhado para cobrar 80% do que voce ESCREVE agora,
                        # nao do que ja existia -- e sem SCM as duas coisas viram
                        # a mesma, tornando o corte impossivel de atingir e o
                        # portao um vermelho permanente que se aprende a ignorar.
                        #
                        # ⚠️ Linha longa de proposito: contrabarra dentro deste
                        # bloco e erro de interpretacao do Groovy.
                        # 🐞 `**/generated/**` NAO PODE FALTAR.
                        #
                        # O `prisma generate` cria `src/generated/prisma`, que e
                        # codigo GERADO e enorme. Sem excluir, medido no build
                        # #18 do live-flow:
                        #
                        #   ncloc     107.061 -> 269.444 linhas
                        #   violacoes            38.716
                        #   cobertura   60,4%  ->   13,1%
                        #
                        # ⚠️ O pior nao e o numero feio: e a cobertura MENTIR
                        # PARA BAIXO. O codigo escrito a mao tem 60% coberto, e o
                        # painel diria 13% -- levando alguem a escrever teste
                        # para um cliente de banco de dados que ninguem manteve
                        # a mao.
                        # 🐞 E `coverage/**` tambem, pelo mesmo tipo de motivo.
                        #
                        # O relator `lcov` gera, junto com o `lcov.info`, um
                        # relatorio HTML em `coverage/lcov-report/`. Sem excluir,
                        # o Sonar ANALISA ESSE HTML e reclama dele:
                        #
                        #   [MAJOR] Remove this deprecated "name" attribute
                        #           coverage/lcov-report/.../route.ts.html
                        #
                        # Duas violacoes "novas" que nao existem no codigo --
                        # existem no relatorio SOBRE o codigo. E como reprovar o
                        # aluno por causa da letra do boletim.
                        #
                        # ⚠️ Excluir da ANALISE nao afeta a leitura do
                        # `lcov.info`: aquilo entra por `lcov.reportPaths`, que e
                        # outro caminho.
                        EXC="**/node_modules/**,**/target/**,**/build/**,**/dist/**,**/.dart_tool/**,**/generated/**,**/*.generated.*,coverage/**"

                        # 🐞 SEPARAR TESTE DE CODIGO. Sem isto o Sonar trata o
                        # arquivo de teste como codigo de producao e COBRA
                        # COBERTURA DELE.
                        #
                        # Medido no live-flow em 21/08/2026, na conta do portao:
                        #
                        #   donate-page.tsx            29 linhas a cobrir
                        #   miniatura-do-video.tsx     27
                        #   tests/doacao-id-de-voz.ts  24   <-- o proprio teste
                        #   proxy.ts                   13
                        #
                        # Um quarto da divida era o teste sendo cobrado de se
                        # testar. Nao faz sentido: quem exercita o teste e ele
                        # mesmo, e nenhum relator de cobertura instrumenta o
                        # proprio arquivo de teste -- entao ele entra como 100%
                        # descoberto e puxa a nota para baixo PARA SEMPRE.
                        #
                        # ⚠️ O efeito e perverso: escrever mais teste PIORAVA a
                        # nota. Cada arquivo novo de teste chegava como divida.
                        # Um portao que pune quem testa ensina a nao testar.
                        #
                        # `sonar.tests` marca a pasta como codigo DE TESTE: o
                        # Sonar continua analisando (bug em teste e bug), mas
                        # para de exigir cobertura dela.
                        TST=""
                        for d in tests test spec __tests__ src/test; do
                            [ -d "$d" ] && TST="${TST:+$TST,}$d"
                        done

                        # ⚠️ A pasta tem que SAIR de fontes para ENTRAR como
                        # teste. `sonar.sources=.` ja engloba `tests/`, e o Sonar
                        # recusa indexar o mesmo arquivo duas vezes:
                        #
                        #   File tests/x.ts can't be indexed twice.
                        #
                        # `sonar.exclusions` vale para FONTES; `sonar.tests` e um
                        # caminho separado, que a exclusao nao alcanca. Entao a
                        # pasta sai de um lado e entra do outro.
                        ARGS_TESTE=""
                        if [ -n "$TST" ]; then
                            ARGS_TESTE="-Dsonar.tests=$TST"
                            for d in $(echo "$TST" | tr "," " "); do
                                EXC="$EXC,$d/**"
                            done
                            echo "==> pastas de teste: $TST"
                        fi
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
                        docker run --rm --network host --add-host sonar.hmg:127.0.0.1 -v "$PWD:/usr/src" -e SONAR_HOST_URL=$SONAR_URL -e SONAR_TOKEN=$SONAR_TOKEN sonarsource/sonar-scanner-cli:latest -Dsonar.projectKey=$SONAR_CHAVE -Dsonar.projectName=$SONAR_CHAVE -Dsonar.sources=. -Dsonar.exclusions="$EXC" $ARGS_TESTE -Dsonar.javascript.lcov.reportPaths=coverage/lcov.info 2>&1 | tee saida-sonar.txt
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
                        #
                        # ⚠️ JDK 25 NA IMAGEM, e nao 21.
                        #
                        # 🐞 O sigma-payments estava VERMELHO desde o build #4 e
                        # ninguem tinha visto -- a falha era no compilador:
                        #
                        #   maven-compiler-plugin:compile FAILED on sigma-payments-core
                        #
                        # Os dois projetos Java declaram `<java.version>25</...>`,
                        # e a imagem trazia JDK 21. Um JDK nao compila para uma
                        # versao mais nova que a dele.
                        #
                        # ⚠️ `test`, e NAO `-DskipTests compile`.
                        #
                        # 🐞 Com `-DskipTests` os testes Java NUNCA rodavam na
                        # esteira. Sao 21 no sigma-payments e 97 no system-api --
                        # todos verdes na maquina, nenhum executado aqui. E sem
                        # execucao nao existe cobertura: o JaCoCo mede
                        # instrumentando a JVM DOS TESTES, entao o portao recebia
                        # 0%% e reprovava projetos que estao bem testados.
                        #
                        # ⚠️ Roda so o surefire. Os `*IT.java` ficam de fora --
                        # sao 14 no sigma-payments e 9 no system-api.
                        #
                        # 🐞 MAS O SUREFIRE NAO PEGA SO `*Test.java`.
                        #
                        # O padrao dele inclui `**/*Tests.java` tambem, e o
                        # `SigmaPaymentsApplicationTests` -- com S no fim -- sobe
                        # Postgres por Testcontainers. Este comentario dizia que
                        # nada aqui precisava do Docker, e estava errado: a
                        # esteira do sigma-payments reprovava por isso.
                        #
                        #   Can't get Docker image: RemoteDockerImage(
                        #     imageName=postgres:16-alpine ...)
                        #   at DockerClientProviderStrategy.getFirstValidStrategy
                        #
                        # ⚠️ A mensagem fala da IMAGEM, e a imagem estava no disco
                        # da VM o tempo todo -- eu cheguei a conferir com um
                        # `docker pull` e ela veio na hora. O que faltava era o
                        # SOCKET: dentro do conteiner nao ha daemon nenhum para
                        # perguntar, e o Testcontainers reporta isso como se a
                        # imagem nao existisse.
                        #
                        # `-v /var/run/docker.sock` entrega o daemon do HOST. Nao
                        # e privilegio novo nesta esteira -- ela ja roda
                        # `docker build` direto, com o mesmo daemon. E com
                        # `--network host` os conteineres que o Testcontainers
                        # sobe ficam alcancaveis por `localhost`, que e onde o
                        # teste os procura.
                        #
                        # 🐞 E `DOCKER_API_VERSION` NAO E OPCIONAL.
                        #
                        # Com o socket montado, o erro MUDOU mas continuou:
                        #
                        #   UnixSocketClientProviderStrategy: failed with
                        #   BadRequestException (Status 400:
                        #   {"message":"client version 1.32 is too old"})
                        #   -> Could not find a valid Docker environment
                        #
                        # ⚠️ A mensagem final fala em "ambiente Docker nao
                        # encontrado", e o socket estava ali. Quem recusou foi o
                        # DAEMON: o Docker 29 desta VM aceita API >= 1.40, e o
                        # docker-java que o Testcontainers 1.21 usa negocia 1.32.
                        #
                        # Ou seja: a biblioteca envelheceu em relacao ao daemon, e
                        # o sintoma aponta para configuracao de ambiente. Fixar a
                        # versao resolve sem mexer em dependencia de projeto
                        # nenhum. `1.44` esta dentro da faixa aceita (o daemon
                        # anuncia 1.55) e e velha o bastante para qualquer
                        # daemon recente.
                        #
                        # 🐞 E `DOCKER_HOST` VAI JUNTO, senao a versao e IGNORADA.
                        #
                        # O Testcontainers tenta estrategias EM ORDEM. Sem
                        # `DOCKER_HOST` definido, quem atende e a
                        # `UnixSocketClientProviderStrategy`, que monta a
                        # configuracao SEM ler `DOCKER_API_VERSION` -- e cai no
                        # padrao 1.32 do docker-java, que e exatamente o valor que
                        # o daemon recusa.
                        #
                        # ⚠️ O sintoma NAO MUDA quando so a versao esta definida: o
                        # log continua dizendo "client version 1.32 is too old",
                        # com a variavel bem visivel na linha do `docker run`. Da
                        # a impressao de que o daemon e teimoso; na verdade a
                        # variavel nunca foi lida.
                        #
                        # Com `DOCKER_HOST` definido, a
                        # `EnvironmentAndSystemPropertyClientProviderStrategy` vem
                        # primeiro, e essa LE as duas.
                        #
                        # 🐞 E NEM ASSIM a variavel de ambiente foi lida.
                        #
                        # Com `DOCKER_HOST` definido a estrategia certa passou a
                        # ser tentada -- e ELA TAMBEM reportou 1.32:
                        #
                        #   EnvironmentAndSystemPropertyClientProviderStrategy:
                        #     failed with ... "client version 1.32 is too old"
                        #
                        # ⚠️ Tres tentativas com o MESMO numero no log, e a cada
                        # uma parecia faltar so mais uma variavel.
                        #
                        # A causa: o `docker-java` NAO le `DOCKER_API_VERSION` do
                        # ambiente. Ele le `DOCKER_HOST`, `DOCKER_TLS_VERIFY`,
                        # `DOCKER_CERT_PATH` e `DOCKER_CONFIG` -- e mais nada. A
                        # versao da API vem de `api.version`, que ele busca em
                        # propriedade de sistema ou no arquivo
                        # `~/.docker-java.properties`.
                        #
                        # ⚠️ Propriedade de sistema NAO SERVE aqui: o surefire
                        # BIFURCA uma JVM propria, e `-D` do Maven nao atravessa a
                        # bifurcacao sem mexer no POM. O ARQUIVO atravessa, porque
                        # e lido do disco pela JVM que precisa dele.
                        #
                        # 🐞 E subir a versao do Testcontainers tambem nao era
                        # saida: 1.21.3 e a mais nova PUBLICADA. Tentei "1.21.6",
                        # que nao existe, e o build morreu em "Non-resolvable
                        # import POM". Antes de trocar versao, conferir o que esta
                        # publicado.
                        #
                        # `DOCKER_HOST` fica porque e correto e barato: aponta o
                        # socket explicitamente, em vez de deixar adivinhar.
                        echo "api.version=1.44" > docker-java.properties

                        # `jacoco:report` explicito porque o POM prende o relatorio
                        # ao `verify`, que nao acontece num `mvn test`.
                        docker run --rm --network host --add-host sonar.hmg:127.0.0.1 -v /var/run/docker.sock:/var/run/docker.sock -e DOCKER_HOST=unix:///var/run/docker.sock -v "$PWD/docker-java.properties:/root/.docker-java.properties:ro" -v "$PWD:/app" -w /app -v jenkins-m2:/root/.m2 maven:3.9-eclipse-temurin-25 mvn -B test org.jacoco:jacoco-maven-plugin:report org.sonarsource.scanner.maven:sonar-maven-plugin:sonar -Dsonar.host.url=$SONAR_URL -Dsonar.token=$SONAR_TOKEN -Dsonar.projectKey=$SONAR_CHAVE 2>&1 | tee saida-sonar.txt
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
                    // 🐞 ACESSO POR PROPRIEDADE, e nao por colchete.
                    //
                    // `r['quem']` parece inocente e o sandbox do Jenkins o
                    // RECUSA:
                    //
                    //   RejectedAccessException: Scripts not permitted to use
                    //   staticMethod org.codehaus.groovy.runtime.DefaultGroovyMethods
                    //
                    // Indexar mapa com colchete chama `DefaultGroovyMethods.getAt`,
                    // que nao esta na lista permitida. `r.quem` faz o mesmo por
                    // um caminho que o sandbox aceita.
                    //
                    // ⚠️ Este defeito so aparecia QUANDO ALGUEM CLICAVA em
                    // promover -- o codigo nunca era executado ate la. O
                    // pipeline ficou "verde" por dias com a promocao quebrada.
                    env.QUEM_APROVOU  = r.quem
                    env.ACAO_PROMOCAO = r.ACAO
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
                    # ⚠️ PRODUCAO E ESTE CLUSTER, desde o corte de 21/08/2026.
                    #
                    # 🐞 Aqui havia uma guarda que exigia `PRD_CONTEXTO` e
                    # imprimia "a producao de verdade ainda roda no Docker da
                    # estacao". Era verdade quando foi escrita, e deixou de ser
                    # no corte -- mas ficou no lugar, e derrubava a promocao
                    # DEPOIS de o dono clicar no botao.
                    #
                    # ⚠️ Guarda que descreve o mundo tem prazo de validade. Esta
                    # sobreviveu ao mundo que ela descrevia por um dia inteiro, e
                    # so apareceu quando alguem finalmente conseguiu clicar em
                    # promover -- porque o botao tambem estava quebrado, por
                    # outro motivo.
                    #
                    # `$KUBECTL` sem `--context` e o cluster LOCAL desta VM, que
                    # e producao. Homologacao usa `$KUBECTL_HMG`, que aponta para
                    # a estacao.
                    K=k8s/overlays/prd/kustomization.yaml
                    A='"'
                    sed -i "s|newTag: .*|newTag: ${A}${TAG}${A}|" "$K"
                    $KUBECTL apply -k k8s/overlays/prd
                '''
            }
        }
"""

# ---------------------------------------------------------------------------
# TESTES COM COBERTURA -- projetos Node cujos testes NAO precisam de banco
#
# ⚠️ Diferente do `TESTES_NODE`: aquele sobe um Postgres descartavel porque o
# conjunto do live-flow fala com banco a cada caso. Aqui os testes sao de
# LOGICA PURA -- fisica, contas de contraste, traducao de linha para JSON -- e
# subir banco seria custo sem retorno: mais 30 segundos por build e mais uma
# peca para falhar num lugar onde nada depende dela.
# ---------------------------------------------------------------------------
TESTES_NODE_SIMPLES = """
        stage('Testes + cobertura') {
            steps {
                sh '''
                    set -e
                    # ⚠️ `pipefail`: sem ele um teste que falha passaria por
                    # sucesso se houvesse cano na linha.
                    set -o pipefail
                    npm ci --no-audit --no-fund --ignore-scripts
                    npx vitest run --coverage
                    echo "==> cobertura em coverage/lcov.info"
                '''
            }
        }
"""


# ---------------------------------------------------------------------------
# TESTES EM DART
#
# ⚠️ Tres projetos deste ambiente sao Dart -- central-ia, opuschat e
# cafe-mobile-erp -- e os tres JA TINHAM teste escrito: 126, 80 arquivos e 88
# arquivos. Nenhum rodava na esteira, porque nao havia molde para eles.
#
# ⚠️ Cada projeto declara a PROPRIA versao do Dart e as PROPRIAS pastas.
#
# Nao da para usar uma imagem so: o `central-ia` compila com `dart:3.9` e os
# outros com `dart:3.12`. Rodar teste numa versao diferente da que constroi a
# imagem e testar outra coisa -- e a diferenca aparece justamente nos casos de
# borda, que e onde o teste serve.
#
# ⚠️ E cada PACOTE resolve as proprias dependencias. Um `pub get` na raiz nao
# alcanca subpacote; e por isso que o laco entra em cada pasta.
#
# `--reporter=expanded` porque o padrao (`compact`) reescreve a mesma linha com
# retorno de carro -- no log do Jenkins isso vira uma linha gigante e ilegivel.
# ---------------------------------------------------------------------------
TESTES_DART = """
        stage('Testes') {
            steps {
                sh '''
                    set -e
                    set -o pipefail

                    # ---------------------------------------------------------
                    # 🐞 A IMAGEM OFICIAL DO DART NAO TRAZ O `libsqlite3.so`.
                    # ---------------------------------------------------------
                    # Os testes que gravam no SQLite -- os que provam isolamento
                    # entre clientes, exigidos pelas Regras de Ouro -- morriam
                    # com "Failed to load dynamic library", e o que aparecia no
                    # log era `LateInitializationError: Local 'db' has not been
                    # initialized`: o erro do tearDown, nao a causa. Facil
                    # atribuir a teste mal escrito e sair mexendo no teste.
                    #
                    # ⚠️ Aqui a biblioteca entra numa CAMADA, e nao num
                    # `apt-get` a cada rodada: o Docker guarda a camada, entao
                    # so a primeira construcao vai a rede. Um `apt-get` por
                    # execucao deixaria a esteira refem do espelho do Debian.
                    # ⚠️ E o pacote sozinho NAO basta: `libsqlite3-0` instala
                    # so o `libsqlite3.so.0`, com a versao no nome, e o Dart
                    # procura por `libsqlite3.so` sem versao. A primeira
                    # tentativa instalou o pacote e os testes continuaram
                    # falhando exatamente com o mesmo erro -- por isso o
                    # atalho para o nome que ele procura.
                    #
                    # O `-` manda o Dockerfile pela ENTRADA e nao usa contexto
                    # nenhum: mandar o repositorio inteiro para o Docker so para
                    # instalar uma biblioteca custaria segundos a cada rodada.
                    docker build -q -t %(tag)s - > /dev/null <<'FIM'
FROM %(imagem)s
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 && rm -rf /var/lib/apt/lists/* && ln -sf "$(ldconfig -p | awk '/libsqlite3.so.0/ { print $NF; exit }')" /usr/lib/libsqlite3.so
FIM

                    for pasta in %(pastas)s; do
                        echo "==> testando $pasta"
                        docker run --rm -v "$PWD:/app" -w "/app/$pasta" %(tag)s sh -c "dart pub get && dart test --reporter=expanded"
                    done
                '''
            }
        }
"""

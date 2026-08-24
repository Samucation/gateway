// ===========================================================================
// PIPELINE do gateway (Kong).
//
// ESCRITO A MAO, e nao gerado por ferramentas/gerar-jenkinsfiles.py -- ao
// contrario das outras nove. O gerador monta pipelines de APLICACAO: constroi
// imagem, empurra para o registro, troca a tag num overlay do kustomize. O
// gateway nao faz nenhuma dessas coisas. Forcar ele no molde distorceria o
// molde para acomodar um caso unico, e e o molde que segura as outras nove.
//
// ---------------------------------------------------------------------------
// ⚠️ ESTE E O UNICO PIPELINE QUE NAO IMPLANTA SOZINHO NA `main`
// ---------------------------------------------------------------------------
// Todo o trafego de todos os projetos passa por aqui, e o Deployment do Kong
// usa `Recreate` -- obrigatorio por causa do `hostPort`, ver a nota em
// vm/k8s.yaml. Ou seja: TODA publicacao do gateway e uma queda total de alguns
// segundos, em tudo ao mesmo tempo.
//
// Um gateway que se republica sozinho a cada commit na `main` transforma um
// ajuste de comentario numa queda geral. Entao:
//
//     * todo push CONFERE   -- as 3 checagens de seguranca e o gerador;
//     * publicar e um ATO   -- marcar o parametro IMPLANTAR ao disparar.
//
// A conferencia e o que tem valor continuo; a publicacao e o que tem risco.
// Separar os dois deixa ficar rigoroso no primeiro sem pagar no segundo.
// ===========================================================================
pipeline {
    agent any

    parameters {
        booleanParam(
            name: 'IMPLANTAR',
            defaultValue: false,
            description: 'Publicar o Kong no cluster. ⚠️ Recreate = queda de alguns segundos em TODAS as rotas, de todos os projetos.')
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 20, unit: 'MINUTES')
        disableConcurrentBuilds()
        timestamps()
    }

    environment {
        // ⚠️ Era `microk8s kubectl`, da VM `serverhomol`. Ela foi desligada em
        // 23/08/2026 e a producao passou para o k3s da distro WSL2 `prd`, onde
        // o proprio Jenkins roda -- entao `kubectl` puro ja fala com ela.
        //
        // 🐞 Enquanto ficou desatualizado, o estagio morria com
        // `microk8s: not found`, que parece binario faltando e e AMBIENTE
        // trocado. Este Jenkinsfile e escrito a mao, entao nao foi corrigido
        // junto com os gerados.
        KUBECTL = 'kubectl'
    }

    stages {

        stage('Preparo') {
            steps {
                sh '''
                    set -e
                    node --version
                    echo "==> commit: ${GIT_COMMIT:-local}"
                '''
            }
        }

        // As 3 checagens que ja existiam no projeto. Elas comparam o gateway
        // gerado contra o Kong de ORIGEM: nenhuma rota pode ter perdido plugin,
        // nenhum projeto pode ter ficado com defesa mais fraca, e nenhuma rota
        // publica pode ficar sem teto de requisicoes.
        stage('Conferir seguranca') {
            steps {
                sh '''
                    set -e
                    npm ci --no-audit --no-fund >/dev/null 2>&1 || npm install --no-audit --no-fund >/dev/null
                    npm run seguranca
                '''
            }
        }

        // ⚠️ O kong.yml e COMMITADO e tambem GERADO. Se os dois discordarem,
        // alguem editou o arquivo gerado a mao -- e a proxima geracao vai
        // silenciosamente desfazer a edicao.
        //
        // O estagio falha nesse caso em vez de aceitar: e a diferenca entre
        // descobrir agora e descobrir quando a rota sumir.
        stage('Gerar e conferir deriva') {
            steps {
                sh '''
                    set -e
                    cp vm/kong.yml /tmp/kong-commitado.yml
                    node vm/gerar-kong-vm.mjs
                    if ! diff -q /tmp/kong-commitado.yml vm/kong.yml >/dev/null; then
                        echo "ERRO: vm/kong.yml commitado difere do que o gerador produz."
                        echo "      Alguem editou o arquivo gerado a mao. As diferencas:"
                        diff /tmp/kong-commitado.yml vm/kong.yml | head -40
                        exit 1
                    fi
                    echo "==> sem deriva: o commitado e exatamente o gerado"
                '''
            }
        }

        stage('Publicar') {
            when { allOf { branch 'main'; expression { params.IMPLANTAR } } }
            steps {
                sh '''
                    set -e
                    echo "==> PUBLICANDO o gateway. Todas as rotas caem por alguns segundos."
                    # KUBECTL sem sudo: o usuario jenkins le o kubeconfig do k3s e
                    # NAO tem sudo sem senha -- com sudo, o script travaria
                    # esperando uma senha ate estourar o tempo limite.
                    KUBECTL="$KUBECTL" bash vm/publicar.sh
                '''
            }
        }

        // Pergunta ao KONG, pelo caminho real, com o cabecalho Host de cada
        // rota. `rollout status` diz que o Pod subiu; ele nao diz que a rota
        // resolve para o lugar certo.
        //
        // ⚠️ 404 aqui e falha de ROTEAMENTO -- o Kong subiu e nao reconheceu o
        // host, que e exatamente o estrago que uma configuracao ruim causa.
        // Qualquer outra resposta (200, 401, ate 502) prova que a rota existe e
        // encontrou um destino; o que o destino respondeu e problema dele.
        stage('Verificar rotas') {
            when { allOf { branch 'main'; expression { params.IMPLANTAR } } }
            steps {
                sh '''
                    set -e
                    falhou=0
                    checa() {
                        c=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -H "Host: $1" "http://127.0.0.1:8050$2" || echo 000)
                        case "$c" in
                            404) echo "    FALHA $1$2 -> 404 (o Kong nao reconheceu o host)"; falhou=1 ;;
                            000) echo "    FALHA $1$2 -> sem resposta"; falhou=1 ;;
                            *)   echo "    ok    $1$2 -> $c" ;;
                        esac
                    }
                    echo "==> rotas publicas, pelo Kong:"
                    checa urupix.com.br /
                    checa www.urupix.com.br /
                    checa urupix.cursodetecnologia.dev.br /
                    checa sigma-midia.cursodetecnologia.dev.br /
                    checa sigma-financeiro.cursodetecnologia.dev.br /
                    checa opuschat.cursodetecnologia.dev.br /
                    checa cafe-api.cursodetecnologia.dev.br /
                    [ "$falhou" = "0" ] || { echo "roteamento quebrado"; exit 1; }
                '''
            }
        }
    }

    post {
        success {
            script {
                if (env.BRANCH_NAME == 'main' && !params.IMPLANTAR) {
                    echo 'Conferencias passaram. NADA foi publicado -- marque IMPLANTAR para publicar.'
                }
            }
        }
        failure {
            sh '''
                $KUBECTL get pods -n gateway || true
                $KUBECTL logs -n gateway deploy/kong --tail=40 2>/dev/null || true
            '''
        }
    }
}

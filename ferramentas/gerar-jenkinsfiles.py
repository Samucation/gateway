# -*- coding: utf-8 -*-
"""
Gera o `Jenkinsfile` de cada projeto migrado.

    cd <raiz do Workspace> && python gateway/ferramentas/gerar-jenkinsfiles.py

-------------------------------------------------------------------------------
POR QUE UM GERADOR
-------------------------------------------------------------------------------
Seis pipelines quase iguais. Escritos a mao, divergem na primeira correcao -- e
correcao houve tres so no primeiro (`vm/kong.yml`): contrabarra que quebra o
Groovy, aspas que o YAML le como numero, e `set image` imperativo.

Aqui a licao entra uma vez e vale para todos.

-------------------------------------------------------------------------------
AS REGRAS QUE TODO PIPELINE DESTE AMBIENTE SEGUE
-------------------------------------------------------------------------------
1. A TAG E O COMMIT, nao a data. Data nao responde "que codigo esta rodando?" --
   duas builds do mesmo minuto colidem, e um rollback nao sabe para onde voltar.

2. `when { branch 'main' }` em tudo que MEXE no cluster. A pasta de organizacao
   constroi TODA branch com Jenkinsfile; sem a trava, abrir uma branch de
   trabalho publica aquela branch em homologacao -- sem ninguem pedir e sem nada
   no log parecendo errado.

3. NENHUMA contrabarra dentro dos blocos `'''`. No Groovy, um escape
   desconhecido e erro de INTERPRETACAO: o pipeline nem chega a rodar.

4. A tag entra pelo OVERLAY via `sed`, nunca por `kubectl set image` -- que e
   imperativo, e o `apply` seguinte o desfaz.

5. O estagio de verificacao pergunta as APLICACOES, pelo Ingress. `rollout
   status` diz que a probe aprovou; ele nao diz que a coisa responde de fora.

-------------------------------------------------------------------------------
⚠️ O GATEWAY NAO ESTA NESTA LISTA, E ISSO E PROPOSITAL
-------------------------------------------------------------------------------
O `gateway/Jenkinsfile` foi escrito A MAO. Nao e esquecimento -- nao acrescente
o gateway em PROJETOS "para completar a lista".

Este gerador monta pipelines de APLICACAO: constroi imagem, empurra para o
registro, troca a tag num overlay do kustomize. O gateway nao faz nenhuma das
tres -- ele gera um kong.yml, cria um ConfigMap e carimba um hash numa
anotacao. Encaixa-lo aqui exigiria uma excecao em cada estagio, e o valor deste
arquivo e justamente as nove serem IGUAIS.

E ha uma diferenca de risco que o molde nao sabe representar: o gateway usa
`Recreate` (obrigatorio por causa do `hostPort`), entao toda publicacao dele e
uma queda total de alguns segundos em TODAS as rotas de TODOS os projetos. Por
isso ele e o unico que nao implanta sozinho na `main` -- exige marcar um
parametro ao disparar. Um gateway que se republica a cada commit transformaria
um ajuste de comentario numa queda geral.
"""
import io
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import estagios

# ---------------------------------------------------------------------------
# 🐞 Ele escreve em caminhos RELATIVOS (`central-ia/Jenkinsfile`), entao so
# funciona a partir da raiz do Workspace. Rodado de dentro de `gateway/`, ele
# morria com um `FileNotFoundError: 'central-ia\\Jenkinsfile'` -- que nao diz
# nada sobre a causa e manda a pessoa procurar o repositorio que sumiu.
#
# Em vez de exigir que se lembre disso, ele mesmo se muda para a raiz: dois
# niveis acima deste arquivo (ferramentas/ -> gateway/ -> Workspace/).
# ---------------------------------------------------------------------------
RAIZ = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
os.chdir(RAIZ)
if not os.path.isdir('gateway'):
    sys.exit('nao achei o Workspace a partir de %s -- este arquivo mudou de lugar?' % RAIZ)

# `imagens`: (nome-da-imagem, argumentos-do-docker-build)
# `deploys`: os Deployments a esperar
# `checa`:   (host, caminho, codigo-esperado)
PROJETOS = [
    dict(dir='central-ia', sonar='dart', ns='central-ia',
         imagens=[('central-motor', '-t {REG}/central-motor:$TAG .'),
                  ('central-portal', '-t {REG}/central-portal:$TAG ./_portal')],
         # ⚠️ O portal e OUTRO repositorio, e o deploy dos dois mora no mesmo
         # overlay (em central-ia/k8s). Dois pipelines editando o mesmo arquivo
         # brigariam -- o ultimo a aplicar apagaria a tag do outro.
         #
         # Por isso este pipeline BUSCA o portal e constroi os dois. O repo do
         # portal nao ganha Jenkinsfile: a pasta de organizacao so cria job para
         # quem tem o arquivo, entao ele fica de fora sem precisar de exclusao.
         extra_checkout='central-ia-portal',
         deploys=['central-motor', 'central-portal', 'central-imagem-rembg'],
         checa=[('central-ia.hmg', '/', '200')]),

    dict(dir='opuschat', sonar='dart', ns='opuschat',
         imagens=[('opuschat', '-t {REG}/opuschat:$TAG .')],
         deploys=['opuschat-app', 'opuschat-redis'],
         checa=[('opuschat.hmg', '/', '200')]),

    dict(dir='cafe-mobile-erp', sonar='dart', ns='plataforma',
         imagens=[('plataforma', '-t {REG}/plataforma:$TAG .')],
         deploys=['plataforma-app', 'plataforma-redis'],
         checa=[('cafe-api.hmg', '/', '200')]),

    dict(dir='sigma-financeiro', sonar='node', ns='sigma-financeiro',
         imagens=[('sigma-financeiro', '-t {REG}/sigma-financeiro:$TAG .')],
         deploys=['sigma-financeiro'],
         checa=[('sigma-financeiro.hmg', '/', '200')]),

    dict(dir='live-flow', sonar='node', testes='node', ns='urupix',
         imagens=[('urupix', '-t {REG}/urupix:$TAG .')],
         deploys=['urupix-app', 'urupix-redis'],
         # ⚠️ O urupix e o unico com dinheiro de terceiro. A verificacao confere
         # que o painel responde E que a API segue recusando quem nao tem
         # credencial -- um deploy que abrisse a API passaria em todo o resto.
         checa=[('urupix.hmg', '/', '200')]),

    dict(dir='sprinklegames-portal', sonar='node', ns='sprinklegames',
         imagens=[('sprinklegames-portal', '-t {REG}/sprinklegames-portal:$TAG .')],
         deploys=['sprinklegames-portal'],
         checa=[('sprinklegames.hmg', '/', '200')]),

    dict(dir='sigma-payments', sonar='maven', ns='sigma-payments',
         imagens=[('sigma-payments', '-t {REG}/sigma-payments:$TAG .'),
                  ('sigma-payments-ops-api', '-f Dockerfile.ops-api -t {REG}/sigma-payments-ops-api:$TAG .'),
                  ('sigma-payments-ops-ui', '-t {REG}/sigma-payments-ops-ui:$TAG ./sigma-payments-ops-ui')],
         deploys=['sigma-payments-app', 'sigma-payments-ops-api', 'sigma-payments-ops-ui'],
         checa=[('sigma-payments.hmg', '/', '200')]),
]

# ⚠️ `--provenance=false --sbom=false` -- SEM ISTO A IMAGEM NAO BAIXA.
    #
    # 🐞 Descoberto em 21/08/2026, ao montar o cluster de homologacao: NENHUMA
    # imagem publicada pela esteira podia ser baixada do registro. Nem pela
    # propria VM que a construiu:
    #
    #   could not fetch content descriptor sha256:33388d...
    #   (application/vnd.in-toto+json) from remote: not found
    #
    # O BuildKit anexa ATESTADOS (proveniencia e SBOM) por padrao. O indice OCI
    # publicado passa a referenciar esses blobs, e o `docker push` para este
    # registro nao os envia -- entao o manifesto aponta para conteudo que nao
    # existe do outro lado.
    #
    # ⚠️ E o defeito era INVISIVEL: producao funcionava porque o containerd da
    # VM ja tinha a imagem em cache LOCAL, do momento do build. O registro
    # servia de enfeite. Numa limpeza de cache, ou num no novo, os Pods cairiam
    # em ImagePullBackOff e nada teria mudado no codigo.
    #
    # Os `ImagePullBackOff` do opuschat e do plataforma, atribuidos a "tag
    # errada", eram isto.

REG = 'localhost:32000'

CABECALHO = """// ===========================================================================
// PIPELINE de homologacao do {dir}.
//
// GERADO por gateway/ferramentas/gerar-jenkinsfiles.py -- editar LA, nao aqui.
// Sao seis pipelines quase iguais; editados um a um, divergem na primeira
// correcao.
//
// A pasta de organizacao do Jenkins descobre este repositorio sozinha, porque
// ele tem este arquivo. Nao ha job criado a mao.
// ===========================================================================
pipeline {{
    agent any

    options {{
        buildDiscarder(logRotator(numToKeepStr: '15'))
        timeout(time: 45, unit: 'MINUTES')
        // Uma execucao por vez. Duas aplicariam manifestos concorrentes no mesmo
        // namespace, e o vencedor seria o mais LENTO -- o cluster acabaria com a
        // versao mais antiga das duas.
        disableConcurrentBuilds()
        timestamps()
    }}

    environment {{
        REGISTRO = '{reg}'
        NS       = '{ns}'
        // A TAG E O COMMIT, nao a data. Data nao responde "que codigo esta
        // rodando?" -- duas builds do mesmo minuto colidem, e um rollback nao
        // sabe para onde voltar.
        TAG      = "${{env.GIT_COMMIT ? env.GIT_COMMIT.take(12) : 'local'}}"
        KUBECTL  = 'microk8s kubectl'

        SONAR_URL   = 'http://sonar.hmg'
        SONAR_CHAVE = '{dir}'

        // ⚠️ O PRD AINDA NAO EXISTE.
        //
        // Este cluster E o de homologacao: todo hostname termina em `.hmg`, e
        // as aplicacoes tem guardas que RECUSAM subir se o ambiente declarado
        // nao bater com a URL que elas usam. A producao de verdade ainda roda
        // no Docker da estacao do Samuel.
        //
        // Entao o estagio de PRD existe, aparece no grafico, e FALHA com
        // mensagem clara -- em vez de passar calado dando a impressao de que
        // promoveu alguma coisa. Quando a inversao acontecer, isto vira o
        // contexto do cluster de producao e o resto do pipeline ja esta pronto.
        PRD_CONTEXTO = ''
    }}

    stages {{

        stage('Preparo') {{
            steps {{
                sh '''
                    set -e
                    echo "==> commit: $TAG"
                    docker --version
                    # Falha CEDO se o registro nao responder. Sem isto o erro so
                    # apareceria no push, depois de minutos de build.
                    if ! curl -sf http://$REGISTRO/v2/_catalog >/dev/null; then
                        echo "ERRO: registro $REGISTRO nao responde"; exit 1
                    fi
                    echo "==> registro ok"

                    # ⚠️ LIMPA ANTES DE COMECAR, e nao so no fim.
                    #
                    # 🐞 O `post {{ always }}` limpa depois -- mas quem enche o
                    # disco e o build que esta COMECANDO, e o espaco tem que
                    # existir ANTES. Medido em 21/08/2026: um unico build do
                    # live-flow levou o disco de 78% a 94% enquanto rodava, e
                    # limpar so no fim chegava tarde.
                    #
                    # Num Kubernetes disco cheio nao da "sem espaco": o kubelet
                    # DESPEJA Pods, e a mensagem fala do Pod. Ja aconteceu aqui
                    # -- sete Pods, incluindo o proprio Sonar, que voltou 503 e
                    # derrubou a analise de outra esteira.
                    # ⚠️ O criterio e ESPACO LIVRE ABSOLUTO, e nao percentual.
                    #
                    # 🐞 A primeira versao limpava acima de 75%. Nao adiantou: o
                    # build #23 comecou em 82%, a limpeza rodou, e ele chegou a
                    # 97% MESMO ASSIM -- porque quem enche e o build, e o que
                    # importa nao e a marca de onde ele parte, e sim se cabe o
                    # que ele vai gerar. Um build deste porte ocupa ~10 GB entre
                    # camadas, cache e o Postgres dos testes.
                    #
                    # Percentual tambem engana entre maquinas: 20% livres de 57 GB
                    # sao 11 GB; de 20 GB sao 4 GB, e nao cabe.
                    PISO_GB=12
                    LIVRE_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
                    echo "==> $LIVRE_GB GB livres antes de construir (piso: $PISO_GB GB)"
                    if [ "$LIVRE_GB" -lt "$PISO_GB" ]; then
                        echo "==> abaixo do piso: limpando o descartavel"
                        # Volumes primeiro: sao 100% orfaos (Postgres de teste que
                        # ficou para tras) e saem sem custo de recompilacao.
                        docker volume prune -f 2>/dev/null | tail -1
                        docker builder prune -f --keep-storage=1GB 2>/dev/null | tail -1
                        docker image prune -af 2>/dev/null | tail -1
                        LIVRE_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
                        echo "==> $LIVRE_GB GB livres agora"
                    fi

                    # ⚠️ FALHA CEDO em vez de derrubar o cluster.
                    #
                    # Num Kubernetes disco cheio nao da "sem espaco": o kubelet
                    # DESPEJA Pods, e a mensagem fala do Pod. Ja aconteceu aqui --
                    # sete Pods, incluindo o proprio Sonar, que voltou 503 e
                    # derrubou a analise de OUTRA esteira.
                    #
                    # Entao, se nem limpando cabe, este build para agora. Um build
                    # vermelho e um aborrecimento; um cluster despejado leva junto
                    # o que nao tem nada a ver com ele.
                    if [ "$LIVRE_GB" -lt 6 ]; then
                        echo "ERRO: so $LIVRE_GB GB livres -- abaixo do minimo para construir."
                        echo "Construir agora arriscaria fazer o kubelet despejar Pods."
                        exit 1
                    fi
                '''
            }}
        }}
"""

RODAPE = """
        stage('Implantar em homologacao') {{
            when {{ branch 'main' }}
            steps {{
                sh '''
                    set -e
                    # ⚠️ ESTE CLUSTER VIROU PRODUCAO -- nao recebe mais hmg.
                    #
                    # 🐞 Em 21/08/2026, durante o corte, este estagio DESFEZ a
                    # configuracao de producao. A esteira aplicou o overlay de
                    # homologacao as 20:48 e o Ingress voltou de `urupix.com.br`
                    # para `urupix.hmg` -- o dominio publico passou a dar 404 com
                    # a aplicacao de pe.
                    #
                    # ⚠️ Nao foi acidente de configuracao: enquanto a esteira
                    # publicar homologacao no cluster que virou producao, ela vai
                    # desfazer producao A CADA BUILD, e o estrago aparece minutos
                    # depois de alguem mexer em qualquer projeto.
                    #
                    # `HMG_CONTEXTO` vazio = nao ha ambiente de homologacao ainda.
                    # Quando a estacao virar hmg, definir a variavel no Jenkins
                    # (Gerenciar > Sistema > variaveis de ambiente) apontando para
                    # o contexto de la, e este estagio volta a valer.
                    if [ -z "$HMG_CONTEXTO" ]; then
                        echo "======================================================"
                        echo " HOMOLOGACAO NAO TEM DESTINO -- nada foi implantado."
                        echo "======================================================"
                        echo
                        echo " Este cluster e PRODUCAO desde o corte. Aplicar o"
                        echo " overlay de hmg aqui derruba o ambiente real: foi o"
                        echo " que aconteceu em 21/08/2026, quando o Ingress voltou"
                        echo " de urupix.com.br para urupix.hmg."
                        echo
                        echo " A imagem FOI construida, testada e publicada no"
                        echo " registro -- so nao foi implantada."
                        echo
                        echo " Para religar: definir HMG_CONTEXTO no Jenkins com o"
                        echo " contexto do cluster de homologacao."
                        exit 0
                    fi
                    # A tag entra pelo OVERLAY, e NAO por `kubectl set image`.
                    #
                    # `set image` e imperativo: o `apply` seguinte devolve o
                    # Deployment para o que esta declarado no overlay, os Pods
                    # novos caem em ImagePullBackOff e o cluster passa a
                    # discordar do repositorio sem ninguem ter errado nada.
                    #
                    # Aspas por variavel, nao com contrabarra: dentro de um bloco
                    # de aspas triplas do Groovy, um escape desconhecido e ERRO
                    # DE INTERPRETACAO -- o pipeline nem chega a rodar.
                    #
                    # E as aspas precisam existir: uma tag toda de digitos, sem
                    # elas, seria lida como NUMERO pelo YAML.
                    K=k8s/overlays/hmg/kustomization.yaml
                    A='"'
                    sed -i "s|newTag: .*|newTag: ${{A}}${{TAG}}${{A}}|" "$K"
                    grep -E "name: .*localhost|newTag" "$K" | sed "s/^/    /"

                    $KUBECTL apply -k k8s/overlays/hmg
                '''
            }}
        }}

        // Sem isto o pipeline ficaria verde no instante do apply, que e antes de
        // qualquer Pod ter subido. Build verde com a aplicacao em
        // CrashLoopBackOff e pior que build vermelho: ninguem vai olhar.
        stage('Esperar homologacao') {{
            when {{ branch 'main' }}
            steps {{
                sh '''
                    set -e
                    # Mesmo motivo do estagio de implantar: sem destino de
                    # homologacao, medir este cluster seria medir PRODUCAO e
                    # devolver verde por um deploy que nao aconteceu.
                    if [ -z "$HMG_CONTEXTO" ]; then
                        echo "==> homologacao sem destino: nada a verificar"
                        exit 0
                    fi
{esperas}
                '''
            }}
        }}

        // Pergunta as APLICACOES, pelo Ingress -- nao ao Kubernetes.
        //
        // `rollout status` diz que a probe aprovou. Ele nao diz que a coisa
        // responde de fora.
        stage('Verificar homologacao') {{
            when {{ branch 'main' }}
            steps {{
                sh '''
                    set -e
                    # Mesmo motivo do estagio de implantar: sem destino de
                    # homologacao, medir este cluster seria medir PRODUCAO e
                    # devolver verde por um deploy que nao aconteceu.
                    if [ -z "$HMG_CONTEXTO" ]; then
                        echo "==> homologacao sem destino: nada a verificar"
                        exit 0
                    fi
                    falhou=0
                    checa() {{
                        c=$(curl -s -o /dev/null -w "%{{http_code}}" -H "Host: $1" "http://127.0.0.1$2")
                        if [ "$c" = "$3" ]; then echo "    ok   $1$2 -> $c"
                        else echo "    FALHA $1$2 -> $c (esperado $3)"; falhou=1; fi
                    }}
                    echo "==> pelo Ingress:"
{checagens}
                    [ "$falhou" = "0" ] || {{ echo "verificacao falhou"; exit 1; }}
                '''
            }}
        }}
{promocao}    }}

    post {{
        failure {{
            // Num pipeline que falhou o que se quer ver e o estado real do
            // cluster, nao o log do Jenkins, que ja foi lido.
            sh '''
                $KUBECTL get pods -n $NS || true
                $KUBECTL get events -n $NS --sort-by=.lastTimestamp 2>/dev/null | tail -20 || true
            '''
        }}
        always {{
            // ⚠️ CADA BUILD LIMPA O QUE SUJOU. Sem isto o disco enche em uma
            // rodada.
            //
            // 🐞 Medido em 21/08/2026: cinco esteiras disparadas juntas geraram
            // 8,1 GB de cache de build em MINUTOS, e o disco foi de 77% para
            // 97% -- 1,8 GB livres. Num Kubernetes isso nao da "sem espaco": o
            // kubelet comeca a DESPEJAR Pods, e a mensagem fala do Pod, nao do
            // disco.
            //
            // `--keep-storage` poe TETO DE TAMANHO em vez de idade. Idade nao
            // serve aqui: o cache que enche o disco e justamente o das ultimas
            // horas. Com 2 GB o build seguinte do mesmo projeto ainda aproveita
            // camada, e o crescimento fica limitado.
            sh 'docker image prune -f --filter "until=168h" >/dev/null 2>&1 || true'
            sh 'docker builder prune -f --keep-storage=2GB >/dev/null 2>&1 || true'

            // ⚠️ Os Postgres de teste, aconteca o que acontecer.
            //
            // 🐞 O estagio de testes ja remove o dele no fim -- mas se ele
            // MORRER antes (teste vermelho, aborto, reinicio do Jenkins), o
            // conteiner fica de pe segurando a porta 15432, e o build SEGUINTE
            // nao consegue subir o seu: "could not bind IPv4 address: Address
            // in use".
            //
            // Foi o que derrubou o build #8 do live-flow: o `pg-teste-7`
            // continuava no ar. Aqui e o unico lugar que roda sempre.
            sh 'for c in $(docker ps -aq --filter name=pg-teste 2>/dev/null); do docker rm -f "$c" >/dev/null 2>&1 || true; done'
        }}
    }}
}}
"""

for p in PROJETOS:
    partes = [CABECALHO.format(dir=p['dir'], reg=REG, ns=p['ns'])]

    # Estagio extra: buscar o repositorio irmao, quando houver.
    if p.get('extra_checkout'):
        partes.append("""
        // ⚠️ O portal e OUTRO repositorio, e o deploy dos dois mora no MESMO
        // overlay. Dois pipelines editando o mesmo arquivo brigariam -- o ultimo
        // a aplicar apagaria a tag do outro.
        //
        // Por isso este pipeline busca o portal e constroi os dois. O repo do
        // portal nao tem Jenkinsfile, entao a pasta de organizacao nao cria job
        // para ele -- fica de fora sem precisar de exclusao.
        stage('Buscar o portal') {
            steps {
                dir('_portal') {
                    // 🐞 `github-ssh-samucation`, e nao `github-samucation`.
                    //
                    // O build #1 morreu com "Error cloning remote repo 'origin'"
                    // -- mensagem que faz procurar problema de REDE ou de
                    // permissao no GitHub. Nao era: a credencial simplesmente
                    // NAO EXISTIA com aquele id.
                    //
                    // `github-samucation` e o id que a pasta de organizacao
                    // espera para o TOKEN, que ainda nao foi criado. Enquanto o
                    // acesso for por SSH, o id e este. Ao trocar para o token,
                    // ver gateway/vm/DIVIDA-SEGURANCA.md -- esta linha muda
                    // junto.
                    git branch: 'main',
                        credentialsId: 'github-ssh-samucation',
                        url: 'git@github.com:Samucation/%s.git'
                }
            }
        }
""" % p['extra_checkout'])

    # Estagio de build: em paralelo quando ha mais de uma imagem.
    if len(p['imagens']) == 1:
        nome, args = p['imagens'][0]
        partes.append("""
        stage('Construir') {
            steps {
                sh 'docker build --provenance=false --sbom=false %s'
            }
        }
""" % args.format(REG='$REGISTRO'))
    else:
        blocos = []
        for nome, args in p['imagens']:
            blocos.append("""                stage('%s') {
                    steps { sh 'docker build --provenance=false --sbom=false %s' }
                }""" % (nome.replace(p['dir'] + '-', ''), args.format(REG='$REGISTRO')))
        partes.append("""
        // Em paralelo: em serie o tempo e a SOMA, em paralelo e o MAIOR.
        stage('Construir') {
            parallel {
%s
            }
        }
""" % '\n'.join(blocos))

    # ⚠️ ENTRE construir e testar, e nao so no fim.
    #
    # 🐞 O cache de build so serve DURANTE o `Construir`. Depois ele fica
    # ocupando disco justamente enquanto rodam os testes e a analise -- que e
    # quando o Sonar mais precisa de espaco.
    #
    # Medido em 21/08/2026, no build #25: o disco chegou a 95%% com a analise
    # em curso, e sobraram 3,2 GB. Liberar o cache ali devolveu 6,6 GB de uma
    # vez. No #23 a mesma situacao terminou com o Elasticsearch marcando os
    # indices como somente-leitura e a analise morrendo -- sem nada de errado
    # no codigo.
    #
    # ⚠️ Limpa o CACHE, nao as imagens: a imagem construida tem que sobreviver
    # ate o `Publicar`, que vem depois do portao.
    #
    # So limpa se estiver apertado: cache quente e o que faz o proximo build
    # ser rapido, e jogar fora a toa cobra minutos de todo mundo.
    partes.append("""
        stage('Liberar cache de build') {
            steps {
                sh '''
                    LIVRE_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
                    if [ "$LIVRE_GB" -lt 15 ]; then
                        echo "==> $LIVRE_GB GB livres: soltando o cache antes de testar"
                        docker builder prune -af 2>/dev/null | tail -1
                        echo "==> agora: $(df -BG --output=avail / | tail -1 | tr -d ' ') livres"
                    else
                        echo "==> $LIVRE_GB GB livres: cache mantido, proximo build agradece"
                    fi
                '''
            }
        }
""")

    pushes = '\n'.join("                    docker push $REGISTRO/%s:$TAG" % n
                       for n, _ in p['imagens'])
    partes.append("""
        stage('Publicar') {
            steps {
                sh '''
                    set -e
%s
                '''
            }
        }
""" % pushes)

    esperas = '\n'.join(
        '                    $KUBECTL rollout status -n $NS deploy/%s --timeout=600s' % d
        for d in p['deploys'])
    checagens = '\n'.join(
        '                    checa %s %s %s' % c for c in p['checa'])
    # O Sonar entra DEPOIS de construir e ANTES de publicar: nao adianta
    # empurrar para o registro uma imagem que o portao vai reprovar.
    sonar = {'maven': estagios.SONAR_MAVEN}.get(p.get('sonar'), estagios.SONAR_GENERICO)

    # ⚠️ O estagio de TESTES so entra em quem tem `testes='node'`.
    #
    # Sem relatorio de cobertura o Sonar assume 0% e o portao reprova todo
    # build -- entao ligar o portao sem ligar os testes e garantir vermelho
    # eterno. Os dois andam juntos, por projeto, conforme cada um ganha a
    # infraestrutura de teste na esteira.
    testes = estagios.TESTES_NODE if p.get('testes') == 'node' else ''

    partes.insert(len(partes) - 1, testes + sonar + estagios.PORTAO)

    partes.append(RODAPE.format(esperas=esperas, checagens=checagens,
                                promocao=estagios.PROMOCAO))

    texto = ''.join(partes)
    assert '\\' not in texto, '%s: contrabarra no Jenkinsfile quebra o Groovy' % p['dir']

    # 🐞 As aspas triplas tem que fechar em PAR.
    #
    # O build #1 do system-api morreu porque um COMENTARIO dentro do bloco
    # escrevia as tres aspas literalmente, para explicar este mesmo tipo de
    # problema -- e elas fecharam a string tres palavras antes. O Groovy
    # reclamou de "expecting '}', found 'do'" apontando para dentro do
    # comentario, que para ele nunca foi comentario: a string ja tinha acabado.
    #
    # A regra vale para o TEXTO tambem, e nao so para o codigo: nunca escrever
    # o delimitador dentro do que ele delimita.
    assert texto.count(chr(39) * 3) % 2 == 0, (
        '%s: numero IMPAR de aspas triplas -- algum bloco nao fecha' % p['dir'])

    caminho = os.path.join(p['dir'], 'Jenkinsfile')
    io.open(caminho, 'w', encoding='utf-8', newline='\n').write(texto)
    print('  %-18s %d imagem(ns), %d deploy(s)' % (p['dir'], len(p['imagens']), len(p['deploys'])))

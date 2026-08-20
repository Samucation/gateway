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
    dict(dir='central-ia', ns='central-ia',
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

    dict(dir='opuschat', ns='opuschat',
         imagens=[('opuschat', '-t {REG}/opuschat:$TAG .')],
         deploys=['opuschat-app', 'opuschat-redis'],
         checa=[('opuschat.hmg', '/', '200')]),

    dict(dir='cafe-mobile-erp', ns='plataforma',
         imagens=[('plataforma', '-t {REG}/plataforma:$TAG .')],
         deploys=['plataforma-app', 'plataforma-redis'],
         checa=[('cafe-api.hmg', '/', '200')]),

    dict(dir='sigma-financeiro', ns='sigma-financeiro',
         imagens=[('sigma-financeiro', '-t {REG}/sigma-financeiro:$TAG .')],
         deploys=['sigma-financeiro'],
         checa=[('sigma-financeiro.hmg', '/', '200')]),

    dict(dir='live-flow', ns='urupix',
         imagens=[('urupix', '-t {REG}/urupix:$TAG .')],
         deploys=['urupix-app', 'urupix-redis'],
         # ⚠️ O urupix e o unico com dinheiro de terceiro. A verificacao confere
         # que o painel responde E que a API segue recusando quem nao tem
         # credencial -- um deploy que abrisse a API passaria em todo o resto.
         checa=[('urupix.hmg', '/', '200')]),

    dict(dir='sprinklegames-portal', ns='sprinklegames',
         imagens=[('sprinklegames-portal', '-t {REG}/sprinklegames-portal:$TAG .')],
         deploys=['sprinklegames-portal'],
         checa=[('sprinklegames.hmg', '/', '200')]),

    dict(dir='sigma-payments', ns='sigma-payments',
         imagens=[('sigma-payments', '-t {REG}/sigma-payments:$TAG .'),
                  ('sigma-payments-ops-api', '-f Dockerfile.ops-api -t {REG}/sigma-payments-ops-api:$TAG .'),
                  ('sigma-payments-ops-ui', '-t {REG}/sigma-payments-ops-ui:$TAG ./sigma-payments-ops-ui')],
         deploys=['sigma-payments-app', 'sigma-payments-ops-api', 'sigma-payments-ops-ui'],
         checa=[('sigma-payments.hmg', '/', '200')]),
]

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
                '''
            }}
        }}
"""

RODAPE = """
        stage('Implantar') {{
            when {{ branch 'main' }}
            steps {{
                sh '''
                    set -e
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
        stage('Esperar ficar de pe') {{
            when {{ branch 'main' }}
            steps {{
                sh '''
                    set -e
{esperas}
                '''
            }}
        }}

        // Pergunta as APLICACOES, pelo Ingress -- nao ao Kubernetes.
        //
        // `rollout status` diz que a probe aprovou. Ele nao diz que a coisa
        // responde de fora.
        stage('Verificar') {{
            when {{ branch 'main' }}
            steps {{
                sh '''
                    set -e
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
    }}

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
            sh 'docker image prune -f --filter "until=168h" >/dev/null 2>&1 || true'
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
                    git branch: 'main',
                        credentialsId: 'github-samucation',
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
                sh 'docker build %s'
            }
        }
""" % args.format(REG='$REGISTRO'))
    else:
        blocos = []
        for nome, args in p['imagens']:
            blocos.append("""                stage('%s') {
                    steps { sh 'docker build %s' }
                }""" % (nome.replace(p['dir'] + '-', ''), args.format(REG='$REGISTRO')))
        partes.append("""
        // Em paralelo: em serie o tempo e a SOMA, em paralelo e o MAIOR.
        stage('Construir') {
            parallel {
%s
            }
        }
""" % '\n'.join(blocos))

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
    partes.append(RODAPE.format(esperas=esperas, checagens=checagens))

    texto = ''.join(partes)
    assert '\\' not in texto, '%s: contrabarra no Jenkinsfile quebra o Groovy' % p['dir']

    caminho = os.path.join(p['dir'], 'Jenkinsfile')
    io.open(caminho, 'w', encoding='utf-8', newline='\n').write(texto)
    print('  %-18s %d imagem(ns), %d deploy(s)' % (p['dir'], len(p['imagens']), len(p['deploys'])))

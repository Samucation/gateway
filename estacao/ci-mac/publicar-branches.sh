#!/bin/sh
# Publica o Jenkinsfile adaptado de cada projeto num BRANCH -- nunca na main.
#
# ⚠️ `git add` POR CAMINHO, nunca `-A`: varios destes repositorios tem
# arquivo solto na arvore (log de erro, .json de teste) que nao deve entrar.
#
# ⚠️ E branch, e nao main, porque na main o proximo push dispara a esteira de
# verdade -- que no fim implanta em PRODUCAO. A validacao no linter diz que a
# gramatica esta certa; nao diz que a build passa.
W=/mnt/e/Desenvolvimento/Dev/Workspace
BR=ci-no-mac

for d in central-ia opuschat cafe-mobile-erp sigma-financeiro live-flow \
         sprinklegames-portal sigma-midia sigma-payments system-api; do
  cd "$W/$d" 2>/dev/null || { echo "  $d: sem repo"; continue; }

  if ! git diff --quiet Jenkinsfile 2>/dev/null; then
    git checkout -q -B "$BR" 2>/dev/null
    git add Jenkinsfile
    git commit -q -m "esteira: parte em CI (divide com o Mac) e CD (fica na estacao)

O padrao de AGENTE_CI e' 'mac-arm || built-in': o Jenkins escolhe quem
estiver livre. Com o MacBook fora da rede a build cai no built-in e nada
para -- ele segue sendo a rede de seguranca.

⚠️ O CD e' 'built-in' EXPLICITO: de um agente remoto o kubectl nao falaria
com cluster nenhum, e o estagio morreria no meio de um deploy.

🐞 A TAG e' recalculada no primeiro estagio. Com 'agent none' o bloco
'environment' pode ser avaliado antes do checkout e GIT_COMMIT vir nulo --
a TAG cairia para 'local', as imagens sairiam ':local' e A ESTEIRA FICARIA
VERDE.

🐞 A guarda de carga aprendeu macOS: nproc e /proc/loadavg nao existem la'.

🐞 O 'docker build' declara --platform: o Mac e' arm64 e o cluster amd64.
Sem isso a imagem sai arm64 e o Pod morre com 'exec format error'.

Gerado por gateway/ferramentas/gerar-jenkinsfiles.py -- editar LA.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" 2>/dev/null

    if git push -q -u origin "$BR" 2>/dev/null; then
      echo "  $d: publicado em $BR"
    else
      echo "  $d: FALHOU o push"
    fi
  else
    echo "  $d: sem mudanca"
  fi
done

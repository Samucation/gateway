#!/bin/sh
# ===========================================================================
# MEDE a construcao das imagens no Mac -- o numero que faltava.
# ===========================================================================
# O estagio `Construir e publicar` tem `when { branch 'main' }` e foi PULADO
# em todas as rodadas de teste (job avulso nao define BRANCH_NAME). Entao a
# parte mais pesada -- tres `docker build` com `mvn package` e `npm ci`
# DENTRO, tudo emulado -- nunca foi medida.
#
# ⚠️ Nao da' para medir definindo BRANCH_NAME=main no job de teste: isso
# ligaria tambem os estagios de DEPLOY, que implantam no site do cliente.
#
# Aqui rodo so' o script de publicacao, no workspace que a build #6 deixou,
# com uma tag de teste. Mesma coisa que o estagio faria, sem o resto.
MAC=192.168.15.25
U=samuelferreiraduarte
CHAVE=/var/lib/jenkins/.ssh/ci-mac
SSH="sudo -u jenkins ssh -i $CHAVE -o BatchMode=yes -o ConnectTimeout=20 -o UserKnownHostsFile=/var/lib/jenkins/.ssh/known_hosts $U@$MAC"
W=/Users/samuelferreiraduarte/jenkins-agente/workspace/zz-cartorio-mac

echo "== o workspace da build #6 ainda esta la? =="
$SSH "[ -f $W/ferramentas/publicar-imagens.sh ] && echo '  sim' || echo '  NAO -- preciso rodar a esteira antes'"

echo
echo "== construindo as tres imagens, com cronometro =="
$SSH "export PATH=\$HOME/.orbstack/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
  cd $W || exit 1
  INICIO=\$(date +%s)
  bash ferramentas/publicar-imagens.sh zz-medicao 2>&1 | tail -25
  FIM=\$(date +%s)
  echo
  echo \"  TEMPO TOTAL: \$((FIM - INICIO))s\"" 2>&1 | sed 's/^/  /'

echo
echo "== o que chegou no registro, e em que arquitetura =="
for i in cartorio-backend cartorio-site cartorio-keycloak; do
  A='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
  D=$(curl -s -m 15 -H "Accept: $A" "http://localhost:32000/v2/$i/manifests/zz-medicao" | grep -o '"architecture":"[^"]*"' | head -1)
  printf '  %-22s %s\n' "$i" "${D:-(nao achei)}"
done

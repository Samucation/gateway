#!/bin/sh
# ===========================================================================
# 🐞 RESQUICIO DO DOCKER DESKTOP QUEBRA O `docker pull` NO AGENTE
# ===========================================================================
# O `~/.docker/config.json` do Mac tem `"credsStore": "osxkeychain"`, escrito
# pelo Docker Desktop. O binario auxiliar (`docker-credential-osxkeychain`)
# vivia junto com ele, em /usr/local/bin -- que foi removido na virada para o
# OrbStack.
#
# Resultado, so' na sessao do Jenkins:
#
#   error getting credentials - err: exec:
#   "docker-credential-osxkeychain": executable file not found in $PATH
#
# ⚠️ E' erro de CREDENCIAL numa puxada de imagem PUBLICA, que nao precisa de
# credencial nenhuma. A mensagem manda procurar login, e o problema e' um
# ajuste orfao.
#
# ⚠️ E so' aparece no agente: no terminal da pessoa o PATH e' outro, entao la'
# funciona. Mais um caso de "funciona na minha maquina" com a mesma maquina.
#
# Guardo o original antes de mexer.
MAC=192.168.15.25
U=samuelferreiraduarte
CHAVE=/var/lib/jenkins/.ssh/ci-mac
SSH="sudo -u jenkins ssh -i $CHAVE -o BatchMode=yes -o ConnectTimeout=20 -o UserKnownHostsFile=/var/lib/jenkins/.ssh/known_hosts $U@$MAC"
D=/Users/samuelferreiraduarte/.orbstack/bin/docker
G=/opt/homebrew/bin/gtimeout

echo "== config.json atual =="
$SSH 'cat ~/.docker/config.json 2>/dev/null | head -20' | sed 's/^/  /'

echo
echo "== o auxiliar existe em algum lugar? =="
$SSH 'for p in /usr/local/bin /opt/homebrew/bin ~/.orbstack/bin /Applications/Docker.app/Contents/Resources/bin; do
        [ -x "$p/docker-credential-osxkeychain" ] && echo "  achado em $p"
      done; echo "  (fim da busca)"'

echo
echo "== guardando copia e removendo o credsStore orfao =="
$SSH 'cd ~/.docker 2>/dev/null || exit 0
  [ -f config.json ] || { echo "  sem config.json"; exit 0; }
  cp -n config.json config.json.antes-do-ci 2>/dev/null && echo "  copia: ~/.docker/config.json.antes-do-ci"
  # Remove so a linha do credsStore, preservando o resto do arquivo.
  sed -i "" "/\"credsStore\"/d" config.json 2>/dev/null || sed -i "/\"credsStore\"/d" config.json
  # Se sobrou virgula solta antes de }, arruma.
  sed -i "" "s/,[[:space:]]*}/}/" config.json 2>/dev/null || true
  echo "  --- depois ---"
  cat config.json | head -12 | sed "s/^/    /"'

echo
echo "== prova: puxar imagem publica nativa =="
$SSH "$G 240 $D pull --platform linux/arm64 alpine:3 2>&1 | tail -3" | sed 's/^/  /'
$SSH "$G 30 $D image inspect alpine:3 --format '  arquitetura: {{.Architecture}}'" 2>&1 | sed 's/^/  /'

echo
echo "== prova final: roda sem aviso de plataforma =="
$SSH "$G 60 $D run --rm alpine:3 uname -m 2>&1 | tail -2" | sed 's/^/  /'

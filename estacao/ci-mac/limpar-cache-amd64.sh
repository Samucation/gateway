#!/bin/sh
# Remove do Mac as imagens de FERRAMENTA que ficaram em amd64.
#
# 🐞 Nos meus testes puxei `alpine:3` com `--platform linux/amd64`. Ela ficou
# no cache SEM sufixo de arquitetura -- entao qualquer `docker run alpine:3`
# posterior pegava a amd64 e rodava EMULADO. Foi assim que um `rm -rf` de
# quatro diretorios atolou a build #2 por 58 minutos.
#
# ⚠️ Cache envenenado nao acusa: o container roda, so' que devagar. O unico
# sinal e' o WARNING de plataforma, que passa despercebido no meio do log.
MAC=192.168.15.25
U=samuelferreiraduarte
CHAVE=/var/lib/jenkins/.ssh/ci-mac
SSH="sudo -u jenkins ssh -i $CHAVE -o BatchMode=yes -o ConnectTimeout=20 -o UserKnownHostsFile=/var/lib/jenkins/.ssh/known_hosts $U@$MAC"
D=/Users/samuelferreiraduarte/.orbstack/bin/docker
G=/opt/homebrew/bin/gtimeout

echo "== imagens de ferramenta e suas arquiteturas =="
$SSH "$G 30 $D images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | head -12" | sed 's/^/  /'

echo
echo "== arquitetura do alpine:3 em cache =="
$SSH "$G 30 $D image inspect alpine:3 --format '  {{.Architecture}}' 2>/dev/null || echo '  (ausente)'"

echo
echo "== removendo para forcar puxada nativa =="
$SSH "$G 60 $D rmi -f alpine:3 2>&1 | tail -2" | sed 's/^/  /'

echo
echo "== puxando a NATIVA (arm64) =="
$SSH "$G 180 $D pull --platform linux/arm64 alpine:3 2>&1 | tail -2" | sed 's/^/  /'
$SSH "$G 30 $D image inspect alpine:3 --format '  agora: {{.Architecture}}'"

echo
echo "== prova: roda sem aviso de plataforma? =="
$SSH "$G 60 $D run --rm alpine:3 uname -m 2>&1 | tail -2" | sed 's/^/  /'

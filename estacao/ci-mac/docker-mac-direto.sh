#!/bin/sh
# 🐞 `timeout` NAO EXISTE no macOS (e' do GNU coreutils). Meus testes
# "com teto de tempo" saiam em `command not found` com saida 0 -- ou seja,
# NAO testaram nada e pareceram bem-sucedidos.
#
# ⚠️ Mesmo padrao de sempre: comando que nao roda devolvendo saida plausivel.
# Aqui o teto vem do proprio ssh/ferramenta, e o docker roda direto.
MAC=192.168.15.25
U=samuelferreiraduarte
CHAVE=/var/lib/jenkins/.ssh/ci-mac
SSH="sudo -u jenkins ssh -i $CHAVE -o BatchMode=yes -o ConnectTimeout=15 -o UserKnownHostsFile=/var/lib/jenkins/.ssh/known_hosts $U@$MAC"
D=/Users/samuelferreiraduarte/.orbstack/bin/docker

echo "== containers =="
$SSH "$D ps -a --format '{{.Names}} | {{.Status}} | {{.Image}}'" 2>&1 | head -8 | sed 's/^/  /'

echo
echo "== imagens alpine =="
$SSH "$D images alpine --format '{{.Repository}}:{{.Tag}} {{.Size}}'" 2>&1 | head -5 | sed 's/^/  /'

echo
echo "== o comando que travou, na unha =="
$SSH "T=\$(mktemp -d); $D run --rm --net none -v \$T:/w -w /w alpine:3 sh -c 'echo DENTRO-OK'; echo \"saida=\$?\"; rm -rf \$T" 2>&1 | tail -4 | sed 's/^/  /'

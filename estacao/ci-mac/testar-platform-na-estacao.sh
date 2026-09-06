#!/bin/sh
# O `docker` da distro `prd` e' `nerdctl` sobre o containerd do k3s. Ele
# aceita `--platform` no build?
#
# ⚠️ Preciso saber ANTES de acrescentar a flag em `publicar-imagens.sh`, que
# e' usado pela esteira que funciona HOJE. Se o nerdctl a recusar,
# acrescenta-la quebraria o cartorio para resolver um problema do Mac -- que
# e' exatamente o contrario do combinado.
echo "== quem e o docker aqui =="
command -v docker | sed 's/^/  /'
head -3 "$(command -v docker)" 2>/dev/null | sed 's/^/  /'

echo
echo "== versao =="
docker --version 2>&1 | head -2 | sed 's/^/  /'

echo
echo "== o build aceita --platform? =="
T=$(mktemp -d)
printf 'FROM alpine:3\nRUN uname -m > /a.txt\n' > "$T/Dockerfile"
if docker build --platform linux/amd64 -t zz-teste-platform "$T" >/tmp/sb.txt 2>&1; then
  echo "  SIM -- build com --platform passou"
  A=$(docker image inspect zz-teste-platform --format '{{.Architecture}}' 2>/dev/null)
  echo "  arquitetura da imagem: ${A:-?}"
  docker rmi -f zz-teste-platform >/dev/null 2>&1
else
  echo "  NAO -- falhou. Ultimas linhas:"
  tail -6 /tmp/sb.txt | sed 's/^/    /'
fi
rm -rf "$T"

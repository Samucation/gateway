#!/usr/bin/env bash
# Puxa a imagem do REGISTRO a mao e mostra o erro por inteiro.
#
#     wsl -d prd -- bash /mnt/e/.../prd-wsl/puxar-o-registro.sh
#
# O registro local e a fonte de todas as NOSSAS imagens. Enquanto ele nao
# sobe, dezenas de Pods ficam em ImagePullBackOff -- o que parece um problema
# em cada um deles, e e um so.
#
# ⚠️ Ele mesmo vem do Docker Hub (`registry:2`, imagem publica), entao esta e
# a unica peca que depende da internet. Se ESTE pull falhar, o motivo importa
# e tem de aparecer inteiro -- por isso aqui a saida nao e cortada.
set -uo pipefail

echo "== configuracao de registro do k3s (pode reescrever enderecos) =="
# ⚠️ Um `mirror` mal configurado faz o containerd procurar `registry:2` no
# registro LOCAL, que esta fora do ar -- e o erro fala de docker.io, apontando
# para a internet, que esta boa. Vale conferir antes de culpar a rede.
cat /etc/rancher/k3s/registries.yaml 2>/dev/null | sed 's/^/  /' || echo "  (sem registries.yaml)"

echo
echo "== conectividade =="
curl -s -o /dev/null -w '  docker hub: %{http_code}\n' --max-time 15 https://registry-1.docker.io/v2/ 2>/dev/null
curl -s -o /dev/null -w '  auth hub:   %{http_code}\n' --max-time 15 https://auth.docker.io/token 2>/dev/null

echo
echo "== puxando docker.io/library/registry:2 =="
k3s crictl pull docker.io/library/registry:2
codigo=$?
echo "  saida: $codigo"

echo
echo "== o que o containerd tem cadastrado agora =="
k3s crictl images 2>/dev/null | head -10 | sed 's/^/  /'

exit "$codigo"

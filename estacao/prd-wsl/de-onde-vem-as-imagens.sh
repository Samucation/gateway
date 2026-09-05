#!/usr/bin/env bash
# De onde o cluster puxaria as imagens, se o containerd perdesse o cadastro?
#
#     wsl -d prd -- bash /mnt/e/.../prd-wsl/de-onde-vem-as-imagens.sh
#
# ⚠️ ESTA E A PERGUNTA QUE DECIDE O CONSERTO.
#
# Quando o `meta.db` do containerd trava, a saida obvia e apaga-lo: destrava na
# hora. So que ele guarda o cadastro de TODAS as imagens, e elas teriam de ser
# baixadas de novo.
#
#   registro em CONTEINER DOCKER  -> vive fora do k3s, sobrevive. Seguro.
#   registro em POD do k3s        -> ovo-e-galinha: para subir o registro
#                                    precisa da imagem dele, que so existe
#                                    no registro. Producao no chao sem saida.
set -uo pipefail

echo "== ha um Docker separado nesta distro? =="
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  echo "  ✅ docker respondendo"
  echo
  echo "== conteineres docker (o registro estaria aqui) =="
  docker ps -a --format '  {{.Names}}  {{.Image}}  {{.Status}}  {{.Ports}}' 2>/dev/null | head -10
  echo
  echo "== imagens do 4saas guardadas no docker =="
  docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' 2>/dev/null \
    | grep -E 'quatrosaas|urupix|cartorio|veltrixa|sigma' | head -12
else
  echo "  ❌ docker nao responde nesta distro"
fi

echo
echo "== o registro atende na 32000? =="
cod=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:32000/v2/ 2>/dev/null)
echo "  http://localhost:32000/v2/ -> $cod"
if [ "$cod" = "200" ]; then
  echo "  ✅ o registro esta DE PE mesmo com o k3s fora -- entao nao e Pod"
  echo
  echo "== o que ele guarda =="
  curl -s --max-time 10 http://localhost:32000/v2/_catalog 2>/dev/null | head -c 600
  echo
else
  echo "  ⚠️ nao respondeu. Se o registro for Pod do k3s, apagar o meta.db"
  echo "     deixa o ambiente sem de onde puxar nada."
fi

echo
echo "== ha backup do meta.db? =="
ls -lh /var/lib/rancher/k3s/agent/containerd/io.containerd.metadata.v1.bolt/ 2>/dev/null | sed 's/^/  /'

#!/usr/bin/env bash
# Os DADOS do registro sobreviveram? E quanto ocupa o acervo do containerd?
#
#     wsl -d prd -- bash /mnt/e/.../prd-wsl/estado-do-acervo.sh
#
# ⚠️ Distincao que decide o conserto:
#
#   acervo do containerd  camadas baixadas. Descartavel: tudo se baixa de novo.
#   PVC do registro       as NOSSAS imagens publicadas. Se isto se perder, a
#                         unica copia sai do codigo -- e cada projeto precisa
#                         reconstruir e publicar de novo.
set -uo pipefail

echo "== PVC do registro (as nossas imagens) =="
PVC=$(ls -d /var/lib/rancher/k3s/storage/*registro* 2>/dev/null | head -1)
if [ -n "$PVC" ]; then
  du -sh "$PVC" 2>/dev/null | sed 's/^/  /'
  echo "  estrutura:"
  find "$PVC" -maxdepth 3 -type d 2>/dev/null | head -6 | sed 's/^/    /'
  echo "  repositorios guardados:"
  find "$PVC" -type d -name '_manifests' 2>/dev/null | sed 's#.*/repositories/##; s#/_manifests##' | head -20 | sed 's/^/    /'
else
  echo "  ❌ nao achei o volume"
fi

echo
echo "== acervo de camadas do containerd (descartavel) =="
du -sh /var/lib/rancher/k3s/agent/containerd/io.containerd.content.v1.content 2>/dev/null | sed 's/^/  /'

echo
echo "== espaco livre =="
df -h / | tail -1 | sed 's/^/  /'

#!/usr/bin/env bash
# As imagens estao BAIXANDO ou o containerd empacou?
#
#     wsl -d prd -- bash /mnt/e/.../prd-wsl/andamento-dos-downloads.sh
#
# ⚠️ Depois de recriar o cadastro do containerd, dezenas de Pods pedem imagem
# ao mesmo tempo. "ContainerCreating" por muito tempo pode ser as duas coisas:
# fila andando devagar (esperar) ou containerd empacado (agir). A diferenca
# esta no TAMANHO do acervo crescendo -- nao no estado dos Pods.
set -uo pipefail

C="k3s crictl"

echo "== acervo do containerd, duas leituras com 30s =="
a=$(du -sm /var/lib/rancher/k3s/agent/containerd/io.containerd.content.v1.content 2>/dev/null | cut -f1)
n1=$($C images 2>/dev/null | tail -n +2 | wc -l)
echo "  agora:  ${a}MB em disco, $n1 imagem(ns) cadastrada(s)"
sleep 30
b=$(du -sm /var/lib/rancher/k3s/agent/containerd/io.containerd.content.v1.content 2>/dev/null | cut -f1)
n2=$($C images 2>/dev/null | tail -n +2 | wc -l)
echo "  +30s:   ${b}MB em disco, $n2 imagem(ns) cadastrada(s)"

echo
if [ "${b:-0}" -gt "${a:-0}" ] || [ "${n2:-0}" -gt "${n1:-0}" ]; then
  echo "  ✅ ANDANDO: $(( b - a ))MB baixados em 30s. E so esperar."
else
  echo "  ⚠️ PARADO em 30s. Pode ser fila serializada num arquivo grande,"
  echo "     mas se repetir, o containerd empacou de novo."
fi

echo
echo "== o registro local, que e a fonte de todo o resto =="
$C images 2>/dev/null | grep -E 'registry|docker.io/library/registry' | sed 's/^/  /' || echo "  ainda nao baixado"
cod=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:32000/v2/ 2>/dev/null)
echo "  http://localhost:32000/v2/ -> $cod"

echo
echo "== Pods por estado =="
kubectl get pods -A --no-headers 2>/dev/null | awk '{print $4}' | sort | uniq -c | sed 's/^/  /'

echo
echo "== quem ja esta servindo =="
kubectl get pods -A --no-headers 2>/dev/null | awk '$4=="Running"' | wc -l | sed 's/^/  Running: /'

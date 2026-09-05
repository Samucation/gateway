#!/usr/bin/env bash
# O disco da distro esta saudavel, ou ha erro de I/O?
#
#     wsl -d prd -- bash /mnt/e/.../prd-wsl/saude-do-disco.sh
#
# Vem depois de um `du` sair com codigo 4 no volume do registro. Antes de
# apagar ou reconstruir qualquer coisa, e preciso saber se o problema e o
# CONTEUDO (corrompido, mas o disco funciona) ou o DISCO (e af mexer piora).
set -uo pipefail

echo "== erros de I/O no kernel =="
dmesg 2>/dev/null | grep -iE 'I/O error|ext4-fs error|blk_update_request|corrupt' | tail -8 | sed 's/^/  /' \
  || echo "  (dmesg vazio ou sem permissao)"
echo "  ---"

echo
echo "== o volume do registro =="
PVC=$(ls -d /var/lib/rancher/k3s/storage/*registro* 2>/dev/null | head -1)
echo "  caminho: ${PVC:-(nao achei)}"
if [ -n "$PVC" ]; then
  # ⚠️ Sem `du -sh`: e ele que sai com erro. Aqui a leitura e passo a passo,
  # para descobrir ATE ONDE da para ler.
  echo "  ls do topo:"
  ls -la "$PVC" 2>&1 | head -6 | sed 's/^/    /'
  echo "  contagem de arquivos (pode demorar):"
  timeout 60 find "$PVC" -type f 2>&1 | wc -l | sed 's/^/    /'
  echo "  erros ao percorrer:"
  timeout 60 find "$PVC" 2>&1 >/dev/null | head -5 | sed 's/^/    /' || echo "    (nenhum)"
fi

echo
echo "== espaco e inodes =="
df -h  / | tail -1 | sed 's/^/  /'
df -i  / | tail -1 | sed 's/^/  /'

echo
echo "== o acervo do containerd =="
timeout 120 du -sh /var/lib/rancher/k3s/agent/containerd/io.containerd.content.v1.content 2>&1 | sed 's/^/  /'

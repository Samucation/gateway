#!/usr/bin/env bash
# Destrava o containerd do k3s quando ele fica preso no "boltdb open".
#
#     wsl -d prd -- bash /mnt/e/.../prd-wsl/destravar-o-containerd.sh
#
# ⚠️ MUDA PRODUCAO: reinicia o k3s. Rode so depois que
# `porque-o-containerd-nao-sobe.sh` disser que ele esta TRAVADO (estado S em
# futex, 0% de CPU, log congelado). Se estiver trabalhando, esperar e o certo
# -- reiniciar no meio de uma abertura de banco cria o estrago de verdade.
#
# ---------------------------------------------------------------------------
# O QUE ESTE SCRIPT NAO FAZ, DE PROPOSITO
# ---------------------------------------------------------------------------
# Nao apaga o `meta.db`. Apagar destrava na hora, e por isso e a primeira
# ideia de todo mundo -- mas leva junto o registro de TODAS as imagens, e o
# registro deste ambiente (`localhost:32000`) vive aqui dentro. Sem imagem
# para subir o registro, nao ha de onde puxar as imagens: a recuperacao vira
# um ovo-e-galinha com producao no chao.
#
# Reiniciar o processo resolve o caso comum -- trava de arquivo orfa deixada
# por desligamento sujo -- sem tocar em dado nenhum.
set -uo pipefail

echo "== antes =="
kubectl get nodes --no-headers 2>/dev/null || echo "  (api fora do ar)"

echo
echo "== parando o k3s =="
# ⚠️ Saida NAO silenciada: comando que muda estado calado e como nao ter rodado.
systemctl stop k3s
sleep 3

echo
echo "== matando restos de containerd/shim =="
# O containerd e filho do k3s, mas um processo preso em futex pode nao morrer
# com o pai. Sobrando, ele segura o arquivo e o k3s novo espera pelo mesmo
# lugar -- a trava se repete e parece que o conserto nao funcionou.
#
# 🐞 A primeira versao usava `pgrep -f 'containerd|containerd-shim'`. O `-f`
# casa a LINHA DE COMANDO inteira, e a linha de comando deste script contem a
# palavra "containerd" -- no proprio nome do arquivo. Ele se matou (exit 9),
# junto com o `buildkitd`, que tambem cita containerd nos argumentos.
#
# `-x` casa o NOME do executavel, exatamente. E o `$$` sai da lista por
# seguranca, caso alguem renomeie o processo um dia.
for p in $(pgrep -x containerd 2>/dev/null; pgrep -x containerd-shim-runc-v2 2>/dev/null); do
  [ "$p" = "$$" ] && continue
  echo "  matando $p ($(cat "/proc/$p/comm" 2>/dev/null))"
  kill -9 "$p" 2>/dev/null
done
sleep 2

restantes=$(pgrep -xc containerd 2>/dev/null || echo 0)
echo "  containerd restantes: $restantes"

echo
echo "== subindo o k3s =="
systemctl start k3s

echo
echo "== esperando o containerd atender (ate 180s) =="
ok=0
for i in $(seq 1 60); do
  if [ -S /run/k3s/containerd/containerd.sock ]; then
    echo "  socket criado na tentativa $i"
    ok=1
    break
  fi
  sleep 3
done
[ "$ok" = "1" ] || { echo "  ❌ o socket nao apareceu -- o banco pode estar corrompido de verdade."; exit 1; }

echo
echo "== esperando o no ficar Ready (ate 180s) =="
for i in $(seq 1 60); do
  estado=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')
  if [ "$estado" = "Ready" ]; then
    echo "  no Ready na tentativa $i"
    break
  fi
  sleep 3
done

echo
kubectl get nodes --no-headers 2>/dev/null

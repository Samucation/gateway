#!/usr/bin/env bash
# ULTIMO RECURSO: recria o cadastro de imagens do containerd.
#
#     wsl -d prd -- bash /mnt/e/.../prd-wsl/recriar-metadados-do-containerd.sh
#
# ⚠️ MUDA PRODUCAO e causa um RE-DOWNLOAD de todas as imagens.
#
# Rode so depois que:
#   1. `porque-o-containerd-nao-sobe.sh` disser TRAVADO (0% de CPU, log parado
#      em "waiting for response from boltdb open");
#   2. `destravar-o-containerd.sh` (reinicio limpo) NAO tiver resolvido --
#      travar no mesmo ponto duas vezes significa que o problema e o arquivo,
#      e nao uma trava orfa.
#
# ---------------------------------------------------------------------------
# POR QUE ISTO E SEGURO AQUI (e nao seria em qualquer lugar)
# ---------------------------------------------------------------------------
# O `meta.db` guarda o CADASTRO das imagens, nao as imagens dos outros dados.
# Perde-lo obriga a baixar tudo de novo, e a pergunta que decide e: baixar DE
# ONDE?
#
#   registry:2                  imagem PUBLICA -> vem do Docker Hub
#   dados do registro           em PVC no disco -> sobrevivem intactos
#   nossas imagens              voltam do registro local, ja de pe
#
# Ou seja: o registro renasce sozinho e traz o resto junto. Se o registro
# fosse uma imagem so nossa, isto seria um ovo-e-galinha com producao no chao
# -- e o conserto teria de ser outro.
#
# ⚠️ O arquivo e MOVIDO, nunca apagado. Se amanha alguem quiser entender por
# que ele travou, o material esta la. Apagar economiza 81 MB e queima a unica
# chance de descobrir a causa.
set -uo pipefail

DIR=/var/lib/rancher/k3s/agent/containerd/io.containerd.metadata.v1.bolt
CARIMBO=$(date +%Y%m%d-%H%M%S)

echo "== confirmando que ele esta travado, e nao lento =="
if [ -S /run/k3s/containerd/containerd.sock ]; then
  echo "  ⚠️ o socket EXISTE -- o containerd subiu. Nao mexa."
  exit 2
fi
echo "  socket ausente, como esperado"

echo
echo "== parando o k3s =="
systemctl stop k3s
sleep 3
for p in $(pgrep -x containerd 2>/dev/null); do
  echo "  matando containerd $p"
  kill -9 "$p" 2>/dev/null
done
sleep 2

echo
echo "== guardando o banco travado =="
if [ ! -f "$DIR/meta.db" ]; then
  echo "  ⚠️ nao existe meta.db -- nada a fazer aqui."
else
  mv "$DIR/meta.db" "$DIR/meta.db.travado-$CARIMBO"
  echo "  $DIR/meta.db -> meta.db.travado-$CARIMBO"
  ls -lh "$DIR" | sed 's/^/  /'
fi

echo
echo "== subindo o k3s =="
systemctl start k3s

echo
echo "== esperando o containerd atender (ate 300s) =="
ok=0
for i in $(seq 1 100); do
  if [ -S /run/k3s/containerd/containerd.sock ]; then
    echo "  ✅ socket criado na tentativa $i"
    ok=1
    break
  fi
  sleep 3
done
[ "$ok" = "1" ] || { echo "  ❌ nem assim. O problema nao e o meta.db."; exit 1; }

echo
echo "== esperando o no ficar Ready (ate 300s) =="
for i in $(seq 1 100); do
  if [ "$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')" = "Ready" ]; then
    echo "  ✅ no Ready na tentativa $i"
    break
  fi
  sleep 3
done
kubectl get nodes --no-headers 2>/dev/null | sed 's/^/  /'

echo
echo "== o registro local precisa voltar PRIMEIRO =="
# ⚠️ Ele e a fonte de todas as nossas imagens. Enquanto nao estiver de pe, os
# outros Pods vao falhar em ImagePullBackOff -- o que e esperado, e nao um
# segundo problema.
for i in $(seq 1 100); do
  cod=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:32000/v2/ 2>/dev/null)
  if [ "$cod" = "200" ]; then
    echo "  ✅ registro de pe na tentativa $i"
    curl -s --max-time 10 http://localhost:32000/v2/_catalog 2>/dev/null | head -c 400
    echo
    break
  fi
  [ $((i % 10)) = 0 ] && echo "  ainda nao ($cod), tentativa $i"
  sleep 3
done

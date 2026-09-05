#!/usr/bin/env bash
# Por que o conteiner do registro sobe e morre?
#
#     wsl -d prd -- bash /mnt/e/.../prd-wsl/porque-o-registro-morre.sh
set -uo pipefail

NS=registro
POD=$(kubectl -n "$NS" get pods -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
echo "pod: ${POD:-(nenhum)}"
[ -n "$POD" ] || exit 1

echo
echo "== como ele terminou =="
kubectl -n "$NS" get pod "$POD" -o jsonpath='{range .status.containerStatuses[*]}  motivo={.lastState.terminated.reason}{"\n"}  codigo={.lastState.terminated.exitCode}{"\n"}  sinal={.lastState.terminated.signal}{"\n"}  mensagem={.lastState.terminated.message}{"\n"}{end}' 2>/dev/null
echo

echo "== log da instancia atual =="
kubectl -n "$NS" logs "$POD" --tail=30 2>&1 | sed 's/^/  /'

echo
echo "== log da instancia ANTERIOR =="
kubectl -n "$NS" logs "$POD" --previous --tail=30 2>&1 | sed 's/^/  /'

echo
echo "== o volume esta montado e legivel? =="
# ⚠️ O registro grava em disco. PVC com dono/permissao errados faz ele morrer
# na partida com uma mensagem curta -- e o Pod so diz "Error".
PVC=$(ls -d /var/lib/rancher/k3s/storage/*registro* 2>/dev/null | head -1)
echo "  volume: ${PVC:-(nao achei)}"
if [ -n "$PVC" ]; then
  ls -ld "$PVC" | sed 's/^/  /'
  du -sh "$PVC" 2>/dev/null | sed 's/^/  tamanho: /'
  echo "  conteudo:"
  ls "$PVC" 2>/dev/null | head -5 | sed 's/^/    /'
fi

echo
echo "== o que o manifesto pede =="
kubectl -n "$NS" get deploy -o jsonpath='{range .items[0].spec.template.spec.containers[0]}  imagem={.image}{"\n"}  comando={.command}{"\n"}  args={.args}{"\n"}  env={.env}{"\n"}{end}' 2>/dev/null
echo

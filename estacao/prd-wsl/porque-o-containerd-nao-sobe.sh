#!/usr/bin/env bash
# O containerd do k3s nao sobe: ele esta TRABALHANDO ou TRAVADO?
#
#     wsl -d prd -- bash /mnt/e/.../prd-wsl/porque-o-containerd-nao-sobe.sh
#
# Sintoma que leva aqui: o k3s repete "Waiting for containerd startup ...
# containerd.sock: no such file or directory" e o no fica NotReady. O log do
# containerd para em "waiting for response from boltdb open".
#
# ⚠️ A distincao importa porque os consertos sao OPOSTOS:
#
#   trabalhando -> so esperar. Mexer agora corrompe o banco de metadados de
#                  verdade, e af o estrago passa a ser real.
#   travado     -> nao adianta esperar; ele fica assim para sempre.
#
# ⚠️ Roda a partir de ARQUIVO: `$(...)` e aspas nao sobrevivem a viagem
# PowerShell -> wsl -> bash.
set -uo pipefail

DB=/var/lib/rancher/k3s/agent/containerd/io.containerd.metadata.v1.bolt/meta.db

echo "== o banco de metadados =="
ls -lh "$DB" 2>/dev/null || echo "  (nao existe)"

echo
echo "== processos containerd =="
for p in $(pgrep containerd 2>/dev/null); do
  # 3o campo do /proc/PID/stat e o estado: R rodando, S dormindo, D em I/O
  # ininterrupto (que e o que trava e nao sai).
  estado=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
  echo "  pid $p estado=$estado espera_em=$(cat "/proc/$p/wchan" 2>/dev/null)"
done

echo
echo "== ele consome CPU? (2 amostras, 5s) =="
# ⚠️ Esta e a medida que decide. boltdb abrindo um banco grande QUEIMA CPU.
# Parado em 0% com o log congelado e trava, nao lentidao.
for p in $(pgrep containerd 2>/dev/null); do
  a=$(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null)
  sleep 5
  b=$(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null)
  echo "  pid $p: $(( (b - a) * 100 / 500 ))% de CPU em 5s (ticks $a -> $b)"
done

echo
echo "== o arquivo esta sendo lido? =="
for p in $(pgrep containerd 2>/dev/null); do
  echo "  pid $p le/escreve:"
  grep -E '^(read_bytes|write_bytes)' "/proc/$p/io" 2>/dev/null | sed 's/^/    /'
done

echo
echo "== quem tem o meta.db aberto =="
achou=0
for fd in /proc/*/fd/*; do
  alvo=$(readlink "$fd" 2>/dev/null) || continue
  case "$alvo" in
    *meta.db*) pid=$(echo "$fd" | cut -d/ -f3)
               echo "  pid $pid ($(cat "/proc/$pid/comm" 2>/dev/null))"
               achou=1;;
  esac
done
[ "$achou" = "1" ] || echo "  ninguem -- o open ainda nem chegou a abrir o arquivo"

echo
echo "== ultimas linhas do log =="
tail -3 /var/lib/rancher/k3s/agent/containerd/containerd.log 2>/dev/null | sed 's/^/  /'

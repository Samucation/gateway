#!/usr/bin/env bash
# Espera o k3s ficar pronto depois de um reinício, e conta a recuperação.
#
#     bash esperar-o-cluster.sh [voltas]
#
# ⚠️ Em ARQUIVO: `awk "{print \$2}"` inline dentro de `wsl.exe -- bash -c "..."`
# perde as aspas e o erro que sai é "unterminated string".
set -uo pipefail
VOLTAS=${1:-20}

for i in $(seq 1 "$VOLTAS"); do
  ativo=$(systemctl is-active k3s 2>/dev/null)
  no=$(kubectl get nodes --no-headers 2>/dev/null | head -1 | awk '{print $2}')
  pods=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c ' Running ')
  total=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l)
  printf '  volta %-3s servico=%-12s no=%-12s pods=%s/%s\n' \
    "$i" "$ativo" "${no:-sem-resposta}" "${pods:-0}" "${total:-0}"

  if [ "$no" = "Ready" ] && [ "${pods:-0}" -gt 0 ]; then
    # 🐞 `kubectl get deploy -A` traz READY como "1/1" na coluna 3, e UP-TO-DATE
    # como "1" na 4. Comparar `$4 != $3` compara "1" com "1/1" e dá SEMPRE
    # diferente -- a conta dizia "28 incompletos" com o cluster inteiro no ar.
    # O certo é partir a fração e comparar os dois lados dela.
    faltam=$(kubectl get deploy -A --no-headers 2>/dev/null \
             | awk '{split($3,a,"/"); if (a[1] != a[2]) c++} END {print c+0}')
    [ "${faltam:-1}" = "0" ] && { echo "  ✅ cluster pronto e todos os Deployments completos"; exit 0; }
    echo "     ($faltam Deployment(s) ainda incompleto(s))"
  fi
  sleep 30
done
echo "  ⚠️ ainda nao completou em $VOLTAS voltas"
exit 1

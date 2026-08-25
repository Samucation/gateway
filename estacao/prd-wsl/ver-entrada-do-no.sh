#!/usr/bin/env bash
# Quem está escutando as portas de ENTRADA do nó (80 e 8050)?
#
# ⚠️ Kong `1/1 Running` não prova que a porta do NÓ está publicada. O `hostPort`
# é feito pelo CNI quando o Pod sobe; se o Pod voltou antes da rede ficar
# pronta — o que acontece depois de um reinício da distro — ele fica saudável
# com a porta do nó sem ninguém.
#
# O sintoma é cruel: por dentro do cluster tudo responde, e de fora TUDO cai.
set -uo pipefail

echo "== portas de entrada do no =="
for p in 80 8050 32000; do
  quem=$(ss -tlnp 2>/dev/null | grep -E ":$p " | head -1 | sed 's/.*users://' | cut -c1-60)
  printf '  %-6s %s\n' "$p" "${quem:-❌ NINGUEM ESCUTANDO}"
done

echo
echo "== o Pod do Kong =="
kubectl get pods -n gateway -o wide --no-headers 2>/dev/null | cut -c1-120 | sed 's/^/  /'
kubectl get deploy kong -n gateway \
  -o jsonpath='  hostPorts declarados: {.spec.template.spec.containers[0].ports[*].hostPort}{"\n"}' 2>/dev/null

echo
echo "== ele responde por dentro do cluster? =="
c=$(kubectl run kongteste$RANDOM -n gateway --rm -i --restart=Never \
    --image=curlimages/curl:8.10.1 --quiet -- \
    -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H 'Host: urupix.com.br' http://kong.gateway.svc.cluster.local:8000/ 2>/dev/null | tr -d '\r')
echo "  pelo Service (ClusterIP): ${c:-000}"

echo
echo "== e pela porta do no? =="
for p in 80 8050; do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H 'Host: urupix.com.br' "http://127.0.0.1:$p/" 2>/dev/null)
  printf '  127.0.0.1:%-5s %s\n' "$p" "${c:-000}"
done

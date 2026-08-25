#!/usr/bin/env bash
# SOCORRO: dá fôlego à probe de partida do Urupix para o Pod parar de morrer.
#
# 🐞 A `startupProbe` bate em `/` com `timeoutSeconds: 1`. A raiz do Next faz
# renderização no servidor e consulta o banco — com a máquina fria, depois de um
# reinício em massa, isso não volta em 1 segundo. O Kubernetes mata o contêiner,
# ele sobe de novo, e o laço se repete: 21 reinícios em 3 horas, com o app
# dizendo "Ready in 83ms" no log.
#
# ⚠️ Isto é REMENDO, aplicado direto no cluster para a produção voltar. O
# conserto de verdade é no repositório (probe numa rota barata, com tempo
# decente) e vem pela esteira — senão o próximo `apply` desfaz isto em silêncio.
set -uo pipefail

echo "== antes =="
kubectl get deploy urupix-app -n urupix -o jsonpath='  timeout={.spec.template.spec.containers[0].startupProbe.timeoutSeconds}s tentativas={.spec.template.spec.containers[0].startupProbe.failureThreshold}{"\n"}' 2>/dev/null

kubectl patch deploy urupix-app -n urupix --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/timeoutSeconds","value":10},
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/failureThreshold","value":60},
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/timeoutSeconds","value":10},
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/timeoutSeconds","value":10}
]' >/dev/null 2>&1 || echo "  (alguma probe não existia — seguindo)"

echo "== depois =="
kubectl get deploy urupix-app -n urupix -o jsonpath='  timeout={.spec.template.spec.containers[0].startupProbe.timeoutSeconds}s tentativas={.spec.template.spec.containers[0].startupProbe.failureThreshold}{"\n"}' 2>/dev/null

echo "== esperando ficar pronto =="
kubectl rollout status deploy/urupix-app -n urupix --timeout=420s | tail -1 | sed 's/^/  /'

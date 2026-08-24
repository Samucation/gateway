#!/usr/bin/env bash
# O que a produção publicou chegou ao registro da homologação, e o cluster de
# hmg está rodando essa imagem?
#
# ⚠️ Duas perguntas diferentes. A imagem estar no registro não prova que o
# cluster a pegou -- e o cluster rodar uma tag antiga com a esteira verde é
# exatamente o tipo de "funcionando" que esconde uma implantação que não houve.
set -uo pipefail
REG_HMG=${REGISTRO_HMG:-192.168.15.9:32001}
K="kubectl --kubeconfig=/var/lib/jenkins/.kube/config-hmg"

echo "== imagens no registro da homologacao =="
curl -s --max-time 10 "http://$REG_HMG/v2/_catalog" \
  | tr ',' '\n' | grep -oE '[a-z0-9-]+' | grep -v repositories | sed 's/^/  /'

echo
echo "== o que cada cluster esta RODANDO =="
printf '  %-26s %-30s %s\n' "carga" "producao" "homologacao"
for par in "urupix:urupix-app" "sigma-financeiro:sigma-financeiro" \
           "opuschat:opuschat-app" "plataforma:plataforma-app" \
           "central-ia:central-motor" "sigma-midia:sigma-midia" \
           "sprinklegames:sprinklegames-portal" "veltrixa:veltrixa-api"; do
  ns=${par%%:*}; dep=${par##*:}
  p=$(kubectl get deploy "$dep" -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  h=$($K get deploy "$dep" -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  printf '  %-26s %-30s %s\n' "$dep" "${p##*/}" "${h##*/}"
done

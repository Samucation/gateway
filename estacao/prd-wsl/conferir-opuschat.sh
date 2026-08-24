#!/usr/bin/env bash
# O `kong.yml` manda `opuschat.cursodetecnologia.dev.br` e
# `cafe-api.cursodetecnologia.dev.br` para o MESMO destino (`plataforma-app`).
# No cluster existem DOIS Deployments: `opuschat/opuschat-app` e
# `plataforma/plataforma-app`, e o Ingress de hoje manda o `opuschat` para o
# primeiro.
#
# Antes de pôr o Kong na frente é preciso saber se os dois servem a mesma coisa.
# Se servirem, tanto faz; se não servirem, pôr o Kong na frente troca o produto
# que responde no domínio — com 200 em ambos, e portanto invisível para
# conferência por código HTTP.
set -uo pipefail

echo "== quem responde hoje, por destino direto no cluster =="
for alvo in "http://opuschat-app.opuschat.svc.cluster.local:8080" \
            "http://plataforma-app.plataforma.svc.cluster.local:8080"; do
  cod=$(kubectl run conferir-$RANDOM --rm -i --restart=Never --image=curlimages/curl:8.10.1 --quiet -- \
        -s -o /dev/null -w '%{http_code}' --max-time 10 "$alvo/" 2>/dev/null | tr -d '\r')
  printf '  %-58s %s\n' "$alvo" "$cod"
done

echo
echo "== imagem de cada Deployment =="
kubectl get deploy -n opuschat -o jsonpath='{range .items[*]}  opuschat/{.metadata.name}: {.spec.template.spec.containers[0].image}{"\n"}{end}'
kubectl get deploy -n plataforma -o jsonpath='{range .items[*]}  plataforma/{.metadata.name}: {.spec.template.spec.containers[0].image}{"\n"}{end}'

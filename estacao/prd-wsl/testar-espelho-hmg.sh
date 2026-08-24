#!/usr/bin/env bash
# Prova que a imagem da producao consegue chegar ao registro da homologacao.
#
# ⚠️ Em ARQUIVO. Inline dentro de `wsl.exe -- bash -c "..."` o `$T` e comido
# pelo shell do Windows e o comando recebe argumento vazio -- o erro que sai
# fala de "filters: parse error", que nao tem nada a ver com o problema.
set -uo pipefail
REG_HMG=${REGISTRO_HMG:-192.168.15.9:32001}

T=$(kubectl get deploy urupix-app -n urupix -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "  imagem de producao: ${T:-NAO ACHEI}"
[ -n "$T" ] || exit 1

docker tag "$T" "$REG_HMG/urupix:teste-espelho" || exit 1
docker push "$REG_HMG/urupix:teste-espelho" 2>&1 | tail -2 | sed 's/^/    /'

echo "  == conferindo do lado de la =="
curl -s --max-time 10 "http://$REG_HMG/v2/urupix/tags/list" | sed 's/^/    /'

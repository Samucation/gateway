#!/usr/bin/env bash
# ===========================================================================
# Chaves que existem no ConfigMap E no Secret do mesmo Deployment — e qual vence.
#
# 🐞 POR QUE ISTO IMPORTA
# ---------------------------------------------------------------------------
# `envFrom` aplica as fontes NA ORDEM, e a ÚLTIMA vence. Nos manifestos daqui a
# ordem é ConfigMap e depois Secret:
#
#     envFrom:
#       - configMapRef: { name: veltrixa-config }    <- overlay de produção
#       - secretRef:    { name: veltrixa-secrets }   <- dump do .env de trabalho
#
# Os Secrets desta produção foram GERADOS a partir do `.env` de cada projeto,
# com TODAS as chaves — inclusive as que o overlay define de propósito para o
# ambiente. Resultado: o `.env` de desenvolvimento sobrescreve, em silêncio, a
# configuração de produção escrita à mão.
#
# Foi assim que `KEYCLOAK_JWK_SET_URI` voltou a apontar para `localhost:8085`
# dentro do cluster, derrubando o login do Veltrixa — com o overlay declarando
# o valor certo, ali do lado, sem efeito nenhum.
#
# ⚠️ Nada acusa. Os dois objetos existem, os dois estão corretos isoladamente, e
# `kubectl describe` mostra as duas fontes sem dizer qual prevaleceu.
# ===========================================================================
set -uo pipefail

achou=0
for ns in $(kubectl get ns -o name 2>/dev/null | sed 's#namespace/##' | grep -vE '^kube-|^default$|^estacao$'); do
  for dep in $(kubectl get deploy -n "$ns" -o name 2>/dev/null | sed 's#deployment.apps/##'); do
    cm=$(kubectl get deploy "$dep" -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].envFrom[*].configMapRef.name}' 2>/dev/null)
    sec=$(kubectl get deploy "$dep" -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].envFrom[*].secretRef.name}' 2>/dev/null)
    [ -n "$cm" ] && [ -n "$sec" ] || continue

    # A ordem real das fontes decide quem vence.
    ordem=$(kubectl get deploy "$dep" -n "$ns" -o jsonpath='{range .spec.template.spec.containers[0].envFrom[*]}{.configMapRef.name}{.secretRef.name}{" "}{end}' 2>/dev/null)
    ultima=$(echo "$ordem" | awk '{print $NF}')

    for c in $cm; do
      for s in $sec; do
        comuns=$(comm -12 \
          <(kubectl get cm "$c" -n "$ns" -o jsonpath='{range .data}{@}{end}' 2>/dev/null | python3 -c 'import sys,json;print("\n".join(sorted(json.load(sys.stdin).keys())))' 2>/dev/null) \
          <(kubectl get secret "$s" -n "$ns" -o jsonpath='{range .data}{@}{end}' 2>/dev/null | python3 -c 'import sys,json;print("\n".join(sorted(json.load(sys.stdin).keys())))' 2>/dev/null))
        [ -n "$comuns" ] || continue
        achou=1
        vence=$([ "$ultima" = "$s" ] && echo "o SECRET (dump do .env)" || echo "o ConfigMap (overlay)")
        echo "  $ns/$dep — vence $vence"
        for k in $comuns; do
          vc=$(kubectl get cm "$c" -n "$ns" -o jsonpath="{.data.$k}" 2>/dev/null | head -c 60)
          vs=$(kubectl get secret "$s" -n "$ns" -o jsonpath="{.data.$k}" 2>/dev/null | base64 -d 2>/dev/null | head -c 60)
          if [ "$vc" = "$vs" ]; then
            printf '    %-32s iguais\n' "$k"
          else
            printf '    %-32s DIFEREM\n      overlay: %s\n      .env   : %s\n' "$k" "$vc" "$vs"
          fi
        done
      done
    done
  done
done

echo
[ "$achou" = "0" ] && echo "  ✅ nenhuma chave disputada" \
  || echo "  ⚠️ chave que DIFERE e em que vence o .env e configuracao de producao perdida"

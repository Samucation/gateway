#!/usr/bin/env bash
# As variáveis que JÁ QUEBRARAM alguma coisa, conferidas onde elas valem:
# dentro do Pod.
#
# ⚠️ Ler o Secret não serve. Vários destes valores continuam errados lá dentro,
# herdados do `.env` do compose — e não fazem mal porque o ConfigMap do overlay
# vem depois no `envFrom` e vence. Quem decide é o Pod.
set -uo pipefail

ver() { # <ns> <app> <variavel> <esperado-contem> <o-que-quebra-se-errar>
  local ns="$1" app="$2" var="$3" bom="$4" risco="$5" pod val nota
  pod=$(kubectl get pods -n "$ns" -l app="$app" --no-headers 2>/dev/null | grep ' Running ' | head -1 | awk '{print $1}')
  if [ -z "$pod" ]; then printf '  %-46s %s\n' "$ns/$var" "sem Pod rodando"; return; fi
  val=$(kubectl exec -n "$ns" "$pod" -- printenv "$var" 2>/dev/null | tr -d '\r')

  if [ -z "$bom" ]; then
    # Esperado VAZIO.
    [ -z "$val" ] && nota="ok (vazia de proposito)" || { nota="⚠️ deveria estar vazia"; }
  elif printf '%s' "$val" | grep -q "$bom"; then
    nota="ok"
  else
    nota="❌ $risco"
  fi
  printf '  %-30s %-42s %s\n' "$ns/$var" "${val:-(vazia)}" "$nota"
}

echo "== o que chega no Pod =="
ver veltrixa   veltrixa-api    KEYCLOAK_JWK_SET_URI  veltrixa-keycloak "login para de funcionar"
ver veltrixa   veltrixa-api    APPLICATION_ENVIRONMENT prd             "producao roda como homologacao"
ver opuschat   opuschat-app    SIGMA_FINANCEIRO_URL  estacao           "venda de planos desligada"
ver plataforma plataforma-app  SIGMA_FINANCEIRO_URL  estacao           "venda de planos desligada"
ver central-ia central-motor   KOKORO_URL            estacao           "voz do Urupix fora do ar"
ver central-ia central-motor   CHATTERBOX_URL        estacao           "vozes clonadas fora do ar"
ver central-ia central-motor   WHISPER_URL           ""                ""
ver urupix     urupix-app      CENTRAL_URL           central-motor     "Urupix nao acha o motor de voz"

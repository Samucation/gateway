#!/usr/bin/env bash
# Os endereços que apontam para o host FUNCIONAM de dentro de um Pod?
#
# ⚠️ `host.docker.internal` é invenção do Docker Desktop. Dentro do k3s ele não
# existe, e `localhost` é o PRÓPRIO Pod — não a máquina. Configuração herdada do
# compose continua parecendo certa no arquivo e aponta para lugar nenhum.
#
# Testa de dentro do Pod que de fato usa cada endereço.
set -uo pipefail

testar() { # <ns> <deployment> <url> <para que serve>
  local ns="$1" dep="$2" url="$3" oq="$4" pod cod
  pod=$(kubectl get pods -n "$ns" -l app="$dep" --no-headers 2>/dev/null | grep ' Running ' | head -1 | awk '{print $1}')
  if [ -z "$pod" ]; then printf '  %-22s %s\n' "$ns/$dep" "sem Pod rodando"; return; fi
  cod=$(kubectl exec -n "$ns" "$pod" -- sh -c \
        "curl -s -o /dev/null -w '%{http_code}' --max-time 6 '$url' 2>/dev/null || echo 000" 2>/dev/null | tr -d '\r')
  local nota="responde"
  [ "$cod" = "000" ] && nota="❌ NAO ALCANCA -- $oq nao funciona"
  printf '  %-22s %-46s %s  %s\n' "$ns/$dep" "$url" "${cod:-000}" "$nota"
}

echo "== enderecos herdados do compose, testados de dentro do Pod =="
testar opuschat   opuschat-app   "http://host.docker.internal:3201/"          "cobranca pelo sigma-financeiro"
testar plataforma plataforma-app "http://host.docker.internal:3201/"          "cobranca pelo sigma-financeiro"
testar veltrixa   veltrixa-api   "http://localhost:8085/realms/veltrixa"      "login (validacao de token)"
testar central-ia central-motor  "http://host.docker.internal:8040/health"    "transcricao de voz (Whisper)"
testar urupix     urupix-app     "http://localhost:8004/health"               "voz Chatterbox"

echo
echo "== o mesmo destino, pelo nome do cluster (quando existe) =="
testar veltrixa   veltrixa-api   "http://veltrixa-keycloak:8080/realms/veltrixa" "login pelo Service do cluster"
testar opuschat   opuschat-app   "http://sigma-financeiro.sigma-financeiro.svc.cluster.local:3200/" "sigma-financeiro no cluster"

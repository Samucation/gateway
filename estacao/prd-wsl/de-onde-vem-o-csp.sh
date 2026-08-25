#!/usr/bin/env bash
# O `Content-Security-Policy` vem da APLICAÇÃO ou do Kong?
#
# ⚠️ A diferença decide quem conserta. Perguntando só pelo domínio público não
# dá para saber: a resposta atravessa os dois.
#
# Aqui a mesma página é pedida em três lugares:
#   1. direto no Pod   (só a aplicação)
#   2. pelo Traefik    (aplicação + Ingress)
#   3. pelo Kong       (tudo)
set -uo pipefail

mostrar() { # <rotulo> <url> <host>
  local cab
  cab=$(kubectl run csp$RANDOM -n urupix --rm -i --restart=Never \
        --image=curlimages/curl:8.10.1 --quiet -- \
        -s -D - -o /dev/null --max-time 20 ${3:+-H "Host: $3"} "$2" 2>/dev/null)
  local csp
  csp=$(printf '%s' "$cab" | grep -i '^content-security-policy' | head -1)
  echo "  == $1 =="
  if [ -z "$csp" ]; then
    echo "     (sem CSP)"
  else
    printf '%s' "$csp" | sed 's/^[^:]*: *//' | tr ';' '\n' | grep -iE 'form-action|default-src' | sed 's/^ */     /'
  fi
}

mostrar "1. direto no Pod (so a aplicacao)" "http://urupix-app.urupix.svc.cluster.local:3100/login" ""
mostrar "2. pelo Traefik (Ingress)"          "http://traefik.kube-system.svc.cluster.local:80/login" "urupix.com.br"
mostrar "3. pelo Kong (entrada real)"        "http://kong.gateway.svc.cluster.local:8000/login" "urupix.com.br"

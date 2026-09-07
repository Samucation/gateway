#!/bin/sh
# Valida TODOS os Jenkinsfiles da casa no linter declarativo do Jenkins.
#
# ⚠️ Oito deles sao GERADOS do mesmo molde: um erro no molde e' um erro em
# oito lugares. Validar um so' nao serve.
W=/mnt/e/Desenvolvimento/Dev/Workspace
T=$(cat /var/lib/jenkins/secrets/api-token)
J=http://127.0.0.1:8080

ruim=0
for d in central-ia opuschat cafe-mobile-erp sigma-financeiro live-flow \
         sprinklegames-portal sigma-midia sigma-payments \
         cartorio-conceicao system-api gateway sempre-mais-barato; do
  A="$W/$d/Jenkinsfile"
  [ -f "$A" ] || { printf '  %-22s (sem Jenkinsfile)\n' "$d"; continue; }

  CK=$(mktemp)
  CRUMB=$(curl -s -m 20 -c "$CK" -u "samuca:$T" "$J/crumbIssuer/api/json" \
          | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)
  S=$(curl -s -m 60 -b "$CK" -u "samuca:$T" -H "Jenkins-Crumb: $CRUMB" \
      -F "jenkinsfile=<$A" "$J/pipeline-model-converter/validate")
  rm -f "$CK"

  case "$S" in
    *"successfully validated"*) printf '  %-22s VERDE\n' "$d" ;;
    *) printf '  %-22s VERMELHO\n' "$d"
       echo "$S" | head -3 | sed 's/^/      /'
       ruim=$((ruim + 1)) ;;
  esac
done

echo
[ "$ruim" = 0 ] && echo "  todas validaram" || echo "  $ruim com problema"
exit $ruim

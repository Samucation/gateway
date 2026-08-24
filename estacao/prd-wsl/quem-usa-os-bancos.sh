#!/usr/bin/env bash
# Para ONDE cada aplicação do cluster aponta o banco — e se é de dentro.
#
# ⚠️ Sobraram contêineres de banco rodando no Docker (`liveflow-db`, `sigma-db`).
# Se alguma aplicação da produção ainda falar com eles, fechar o Docker derruba
# a produção — que é exatamente o que este arranjo existe para impedir.
#
# A pergunta não se responde olhando o contêiner: responde-se olhando para onde
# a aplicação APONTA.
set -uo pipefail

for par in "urupix:urupix-app" "sigma-financeiro:sigma-financeiro" \
           "central-ia:central-motor" "plataforma:plataforma-app" \
           "opuschat:opuschat-app" "sigma-midia:sigma-midia" \
           "veltrixa:veltrixa-api" "sprinklegames:sprinklegames-portal"; do
  ns="${par%%:*}"; dep="${par##*:}"
  seg=$(kubectl get deploy "$dep" -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].secretRef.name}' 2>/dev/null)
  url=""
  if [ -n "$seg" ]; then
    for chave in DATABASE_URL DATABASE_URL_MOTOR SPRING_DATASOURCE_URL POSTGRES_HOST DB_HOST; do
      v=$(kubectl get secret "$seg" -n "$ns" -o jsonpath="{.data.$chave}" 2>/dev/null | base64 -d 2>/dev/null)
      [ -n "$v" ] && { url="$chave=$v"; break; }
    done
  fi
  # Esconde a senha: isto pode acabar num log.
  limpo=$(echo "$url" | sed -E 's#://[^:]+:[^@]+@#://***:***@#')
  printf '  %-18s %s\n' "$ns" "${limpo:-(sem variavel de banco encontrada)}"
done

echo
echo "== o destino resolve DENTRO do cluster? =="
for h in urupix-postgres.urupix sigma-db.sigma-financeiro central-postgres-motor.central-ia \
         plataforma-postgres.plataforma veltrixa-postgres.veltrixa; do
  ip=$(kubectl run resolve-$RANDOM --rm -i --restart=Never --image=busybox:1.36 --quiet -- \
       nslookup "$h.svc.cluster.local" 2>/dev/null | grep -A1 "$h" | grep Address | tail -1 | awk '{print $NF}')
  printf '  %-38s %s\n' "$h" "${ip:-NAO RESOLVE}"
done

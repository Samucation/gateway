#!/usr/bin/env bash
# As chaves do Urupix no cluster são AS MESMAS do `.env` que funcionava?
#
# ⚠️ Duas chaves decidem se o usuário consegue entrar e se o que está gravado
# continua legível:
#
#   AUTH_SECRET           assina o cookie de sessão. Trocou -> todo mundo
#                         deslogado, e sessões antigas viram lixo.
#   TOKEN_ENCRYPTION_KEY  cifra os tokens do Google guardados no banco. Trocou
#                         -> os tokens existentes NÃO abrem mais, e o sintoma
#                         não é "chave errada": é o YouTube parar de responder
#                         e o app parecer quebrado no login.
#
# Compara SEM imprimir as chaves: só o tamanho e um resumo curto.
set -uo pipefail
ENV_ARQ=${1:-/mnt/e/Desenvolvimento/Dev/Workspace/live-flow/.env}
pod=$(kubectl get pods -n urupix -l app=urupix-app --sort-by=.status.startTime --no-headers 2>/dev/null \
      | grep ' Running ' | tail -1 | awk '{print $1}')

resumo() { printf '%s' "$1" | sha256sum | cut -c1-10; }

[ -f "$ENV_ARQ" ] || { echo "  ⚠️ nao achei $ENV_ARQ -- sem base de comparacao"; exit 1; }

printf '  %-24s %-22s %-22s %s\n' "chave" "no .env" "no cluster" "bate?"
for k in AUTH_SECRET TOKEN_ENCRYPTION_KEY AUTH_GOOGLE_ID AUTH_GOOGLE_SECRET; do
  # Do `.env`: tira aspas e CR (arquivo salvo no Windows quebra a comparacao).
  a=$(grep -E "^${k}=" "$ENV_ARQ" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'\r')
  b=$(kubectl exec -n urupix "$pod" -- printenv "$k" 2>/dev/null | tr -d '\r')
  if [ -z "$a" ] && [ -z "$b" ]; then nota="as duas vazias"
  elif [ -z "$a" ]; then nota="so no cluster"
  elif [ -z "$b" ]; then nota="❌ FALTA no cluster"
  elif [ "$a" = "$b" ]; then nota="✅ igual"
  else nota="❌ DIFERENTE"
  fi
  printf '  %-24s %-22s %-22s %s\n' "$k" \
    "$([ -n "$a" ] && echo "$(resumo "$a") (${#a})" || echo "-")" \
    "$([ -n "$b" ] && echo "$(resumo "$b") (${#b})" || echo "-")" \
    "$nota"
done

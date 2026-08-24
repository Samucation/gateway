#!/usr/bin/env bash
# Prova que o login do Veltrixa funciona: pega token no Keycloak e usa na API.
#
# ⚠️ Não basta a API subir. Ela subia com `KEYCLOAK_JWK_SET_URI` apontando para
# `localhost:8085` — que dentro do Pod é o próprio Pod — e só falhava na hora de
# validar um token. Pod pronto, probe verde, login quebrado.
#
# A prova é um token de verdade atravessando a validação.
set -uo pipefail

NS=veltrixa
api=$(kubectl get pods -n "$NS" -l app=veltrixa-api --no-headers 2>/dev/null | grep ' Running ' | head -1 | awk '{print $1}')
[ -n "$api" ] || { echo "  sem Pod da API"; exit 1; }

ler() { kubectl get secret veltrixa-secrets -n "$NS" -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d; }
USUARIO=$(ler KEYCLOAK_AUTH_USER)
SENHA=$(ler KEYCLOAK_AUTH_PASS)
CLIENTE=$(kubectl get cm veltrixa-config -n "$NS" -o jsonpath='{.data.KEYCLOAK_CLIENT_ID}' 2>/dev/null)
CLIENTE=${CLIENTE:-veltrixa-web}

CLIENTE_API=$(ler KEYCLOAK_CLIENT_ID)
SEGREDO=$(ler KEYCLOAK_CLIENT_SECRET)

echo "  cliente do navegador: $CLIENTE"
echo "  cliente de servico:   ${CLIENTE_API:-veltrixa-api}"

echo
echo "== 1. pedindo token ao Keycloak, de dentro do cluster =="
# ⚠️ `client_credentials` com o cliente CONFIDENCIAL, e não `password` com o
# cliente do navegador.
#
# 🐞 A primeira versão tentava `password` com `veltrixa-web` e levava
# "Client not allowed for direct access grants" -- que NÃO é defeito: é o
# cliente público estar corretamente proibido de trocar senha por token. Ler
# aquilo como falha de login mandaria consertar uma configuração que está certa.
TOKEN=$(kubectl exec -n "$NS" "$api" -- sh -c \
  "curl -s --max-time 15 -X POST \
   -d 'grant_type=client_credentials' \
   --data-urlencode 'client_id=${CLIENTE_API:-veltrixa-api}' \
   --data-urlencode 'client_secret=$SEGREDO' \
   http://veltrixa-keycloak:8080/realms/veltrixa/protocol/openid-connect/token" 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("access_token") or "ERRO:"+str(d.get("error_description") or d.get("error")))' 2>/dev/null)

case "$TOKEN" in
  ERRO:*) echo "  ❌ o Keycloak recusou: ${TOKEN#ERRO:}"; exit 1 ;;
  "")     echo "  ❌ sem resposta do Keycloak"; exit 1 ;;
  *)      echo "  ✅ token emitido (${#TOKEN} caracteres)" ;;
esac

echo
echo "== 1b. o que o token diz =="
# ⚠️ O `iss` do token tem de bater EXATAMENTE com `KEYCLOAK_ISSUER_URI` da API.
# Se não bater, a resposta é 401 -- o mesmo código de "não achei as chaves", e a
# mensagem não distingue. Sem olhar o `iss`, um problema vira o outro.
python3 -c "
import base64, json, sys
p = '$TOKEN'.split('.')[1]
p += '=' * (-len(p) % 4)
d = json.loads(base64.urlsafe_b64decode(p))
print('    iss no token:', d.get('iss'))
print('    azp         :', d.get('azp'))
" 2>/dev/null
echo "    esperado pela API: $(kubectl get cm veltrixa-config -n "$NS" -o jsonpath='{.data.KEYCLOAK_ISSUER_URI}' 2>/dev/null)"

echo
echo "== 2. usando o token na API =="
# ⚠️ O que interessa é a API ACEITAR a assinatura. 200 e 403 provam isso do
# mesmo jeito -- 403 é "quem você é não pode", que já passou pela validação.
# 401 é o que aparecia antes: a API não conseguia buscar as chaves.
cod=$(kubectl exec -n "$NS" "$api" -- sh -c \
      "curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
       -H 'Authorization: Bearer $TOKEN' http://localhost:8080/api/platform/companies" 2>/dev/null | tr -d '\r')
echo "  /api/platform/companies -> $cod"
case "$cod" in
  401) echo "  ❌ 401: a API NAO validou o token -- e o sintoma de JWKS inalcancavel"; exit 1 ;;
  200|403|404) echo "  ✅ a assinatura foi aceita (o codigo diz respeito a permissao/rota, nao a autenticacao)" ;;
  *) echo "  ⚠️ codigo inesperado; conferir a mao" ;;
esac

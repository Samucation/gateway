#!/usr/bin/env bash
# O login do Urupix: o que dá para provar SEM a conta Google do usuário.
#
# O fluxo é OAuth com o Google, então não dá para "logar" de script. Mas dá para
# provar as pernas que quebram em migração — e todas elas dão a mesma tela em
# branco para quem tenta entrar:
#
#   1. o app responde e serve a tela de login;
#   2. o Auth.js está montado (providers/csrf/session respondem);
#   3. o pedido sai com o `redirect_uri` que o Google tem cadastrado;
#   4. a SESSÃO consegue ser assinada e lida de volta (AUTH_SECRET coerente);
#   5. o banco aceita gravar sessão/conta (o callback grava).
set -uo pipefail
BASE=${BASE_URUPIX:-https://urupix.com.br}
pod=$(kubectl get pods -n urupix -l app=urupix-app --sort-by=.status.startTime --no-headers 2>/dev/null \
      | grep ' Running ' | tail -1 | awk '{print $1}')

echo "== 1. o app responde =="
for p in / /login /api/auth/providers /api/auth/csrf /api/auth/session; do
  printf '  %-24s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE$p")"
done

echo
echo "== 2. variaveis que decidem a sessao =="
for v in AUTH_URL NEXTAUTH_URL AUTH_TRUST_HOST; do
  printf '  %-18s %s\n' "$v" "$(kubectl exec -n urupix "$pod" -- printenv "$v" 2>/dev/null | tr -d '\r')"
done
for v in AUTH_SECRET AUTH_GOOGLE_ID AUTH_GOOGLE_SECRET; do
  val=$(kubectl exec -n urupix "$pod" -- printenv "$v" 2>/dev/null | tr -d '\r')
  printf '  %-18s %s\n' "$v" "$([ -n "$val" ] && echo "presente (${#val} caracteres)" || echo "❌ VAZIA")"
done

echo
echo "== 3. o banco aceita gravar sessao? =="
# ⚠️ O callback do Google GRAVA em `Account`/`Session`. Banco somente-leitura ou
# migracao pendente derruba o login DEPOIS do Google -- e o usuario volta para a
# tela inicial sem erro nenhum na tela.
kubectl exec -n urupix urupix-postgres-0 -- psql -U liveflow -d liveflow -tAc \
  "SELECT 'contas=' || (SELECT count(*) FROM \"Account\") ||
          '  sessoes=' || (SELECT count(*) FROM \"Session\") ||
          '  usuarios=' || (SELECT count(*) FROM \"User\")" 2>/dev/null | sed 's/^/  /'

echo
echo "== 4. erros de autenticacao no log =="
kubectl logs -n urupix "$pod" --tail=400 2>&1 \
  | grep -iE 'auth|oauth|session|jwt|callback' | grep -iE 'error|erro|fail' \
  | tail -8 | cut -c1-140 | sed 's/^/    /'
echo "  (nada acima = nenhum erro de login registrado)"

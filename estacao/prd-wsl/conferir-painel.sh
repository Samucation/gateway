#!/usr/bin/env bash
# Confere que os PAINEIS do Jenkins estao servidos e com conteudo.
#
# ⚠️ Em arquivo: `$(tr -d "\r\n" < ...)` dentro de `wsl -- bash -c "..."` chega
# mastigado, e o token sai vazio -- o que aparece como 401 e parece token
# invalido, quando o token esta certo e nunca chegou.
set -uo pipefail

J=http://127.0.0.1:8080
U=samuca
T=$(tr -d '\r\n' < /var/lib/jenkins/secrets/api-token 2>/dev/null)

echo "  token: ${#T} chars"

conferir() {
  local caminho="$1" esperado="$2"
  local cod tam
  cod=$(curl -s -o /tmp/p.out -w '%{http_code}' --max-time 15 -u "$U:$T" "$J/$caminho")
  tam=$(stat -c%s /tmp/p.out 2>/dev/null)
  printf '  %-44s http=%-4s %6s bytes' "${caminho:0:44}" "$cod" "$tam"
  # ⚠️ 200 nao basta: o Jenkins devolve 200 com pagina de erro em varios casos.
  # Confere que o conteudo ESPERADO esta la dentro.
  if [ -n "$esperado" ] && grep -q "$esperado" /tmp/p.out 2>/dev/null; then
    echo "  ✅ contem '$esperado'"
  elif [ -n "$esperado" ]; then
    echo "  ❌ SEM '$esperado'"
  else
    echo
  fi
}

conferir 'userContent/painel/painel.html' 'painel.js'
conferir 'userContent/painel/painel.js'   'ESPERANDO SUA APROVACAO'
conferir 'userContent/painel/painel.css'  'viva'
conferir 'userContent/tema/cinza.css'     'background'
conferir 'userContent/painel/jobs.json'   ''
conferir 'view/Painel/api/json?tree=jobs%5Bname%5D' 'main'
conferir 'view/Todas%20as%20esteiras/api/json?tree=jobs%5Bname%5D' 'main'

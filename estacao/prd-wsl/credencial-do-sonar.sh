#!/usr/bin/env bash
# ===========================================================================
# Cria o token do SonarQube e entrega ao Jenkins como credencial.
#
#     wsl -d prd -u root -- bash credencial-do-sonar.sh
#
# Idempotente: se a credencial ja existe, nao faz nada.
# ===========================================================================
#
# 🐞 A esteira falhava com
#
#     ERROR: Could not find credentials entry with ID 'sonar-token'
#
# ...que parece problema de permissao no Jenkins e e ausencia pura: o
# `jenkins-credencial-sonar.groovy` monta a credencial A PARTIR de
# `/var/lib/jenkins/secrets/sonar-token`, e esse arquivo veio da VM. Num
# Jenkins novo ele nao existe, o script avisa e segue -- e a falta so aparece
# la na frente, no estagio do Sonar.
set -uo pipefail

diga() { echo "  $*"; }
ARQ=/var/lib/jenkins/secrets/sonar-token

if [ -s "$ARQ" ]; then
  diga 'token do sonar ja existe'
else
  # ⚠️ A senha inicial do Sonar e `admin/admin`, e ele EXIGE a troca no
  # primeiro acesso. Sem trocar, toda chamada a API responde 401 -- que parece
  # credencial errada e e conta ainda nao ativada.
  NOVA=$( { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom || true; } | head -c 20)

  diga 'trocando a senha inicial do admin...'
  curl -s -o /dev/null -u 'admin:admin' -X POST \
    "http://sonar.hmg/api/users/change_password?login=admin&previousPassword=admin&password=${NOVA}" \
    --max-time 30 || true

  # Guarda a senha: sem ela ninguem entra na tela do Sonar depois.
  printf 'ADMIN_PASSWORD=%s\n' "$NOVA" >> /var/lib/prd-segredos/sonarqube.env
  chmod 600 /var/lib/prd-segredos/sonarqube.env

  diga 'gerando o token de analise...'
  TOKEN=$(curl -s -u "admin:${NOVA}" -X POST \
          "http://sonar.hmg/api/user_tokens/generate?name=jenkins-$(date +%s)" \
          --max-time 30 \
          | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)

  if [ -z "$TOKEN" ]; then
    diga '⚠️ nao consegui gerar o token -- o Sonar ja subiu por completo?'
    curl -s --max-time 10 http://sonar.hmg/api/system/status | head -c 120
    echo
    exit 1
  fi
  printf '%s' "$TOKEN" > "$ARQ"
  chown jenkins:jenkins "$ARQ"
  chmod 600 "$ARQ"
  diga 'token gravado'
fi

# ⚠️ O script `.groovy` roda na PARTIDA do Jenkins. Ele ja esta instalado em
# `init.groovy.d`, entao basta reiniciar para ele achar o arquivo e montar a
# credencial `sonar-token`.
diga 'reiniciando o Jenkins para ele registrar a credencial...'
systemctl restart jenkins
for i in $(seq 1 40); do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:8080/login || true)
  if [ "$c" = "200" ] || [ "$c" = "403" ]; then break; fi
  sleep 5
done
journalctl -u jenkins -n 120 --no-pager 2>/dev/null | grep -i 'sonar' | tail -3

#!/usr/bin/env bash
# O ERRO de um estagio especifico, num build especifico.
#
#     bash erro-do-estagio.sh <projeto> <build|lastBuild> <texto-do-estagio> [linhas]
#
# ⚠️ Le o trecho ENTRE o marcador do estagio pedido e o do proximo. Os outros
# scripts daqui mostram o RABO do console -- e o rabo de um pipeline que falha
# no meio e o `post`, que quase sempre imprime `kubectl get pods` com Pods em
# Error de coisas sem relacao. Eu mesmo cai nisso duas vezes no mesmo dia.
set -uo pipefail

J=http://127.0.0.1:8080
U=samuca
T=$(tr -d '\r\n' < /var/lib/jenkins/secrets/api-token 2>/dev/null)
[ -z "$T" ] && { echo "  ⚠️ sem token em /var/lib/jenkins/secrets/api-token"; exit 3; }

PROJ=${1:?informe o projeto}
BUILD=${2:?informe o numero do build ou lastBuild}
ESTAGIO=${3:?informe o texto do estagio}
N=${4:-60}

curl -s --max-time 120 -u "$U:$T" \
  "$J/job/$PROJ/job/main/$BUILD/consoleText" 2>/dev/null \
| awk -v alvo="($ESTAGIO)" '
    # Liga ao encontrar o marcador do estagio pedido; desliga no PROXIMO
    # marcador. Sem o desligamento, um estagio curto arrastaria a saida do
    # resto do pipeline junto e o erro real ficaria enterrado.
    index($0, "[Pipeline] { " alvo) { dentro=1; next }
    dentro && /^\[Pipeline\] \{ \(/ { exit }
    dentro && !/^\[Pipeline\]/ { print }
  ' \
| grep -viE '^\s*$' \
| tail -"$N" \
| cut -c1-170 \
| sed 's/^/    /'

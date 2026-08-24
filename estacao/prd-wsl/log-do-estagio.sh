#!/usr/bin/env bash
# Mostra o trecho do console entre dois marcadores de estagio.
#     bash log-do-estagio.sh <projeto> <texto-do-estagio> [linhas]
set -uo pipefail
J=http://127.0.0.1:8080
T=$(tr -d '\r\n' < /var/lib/jenkins/secrets/api-token)
n=${3:-25}
curl -s --max-time 40 -u "samuca:$T" "$J/job/$1/job/main/lastBuild/consoleText" 2>/dev/null \
  | grep -A "$n" "($2)" | grep -vE '^\[Pipeline\]' | head -"$n" | cut -c1-130 | sed 's/^/    /'

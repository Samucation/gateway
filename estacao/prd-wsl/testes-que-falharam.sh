#!/usr/bin/env bash
# QUAIS testes falharam num build — direto ao ponto.
#
#     bash testes-que-falharam.sh <projeto> <build|lastBuild>
#
# ⚠️ Em ARQUIVO, e nao inline. O pipe com `grep -E` cheio de simbolos (×, ❯, ✓)
# passa pelo `wsl.exe -- bash -c "..."` do PowerShell e chega mastigado: cada
# simbolo vira "command not found". Mesma armadilha do `esteira.sh`.
set -uo pipefail

J=http://127.0.0.1:8080
U=samuca
T=$(tr -d '\r\n' < /var/lib/jenkins/secrets/api-token 2>/dev/null)
[ -z "$T" ] && { echo "  ⚠️ sem token"; exit 3; }

PROJ=${1:?informe o projeto}
BUILD=${2:-lastBuild}

CONSOLE=$(curl -s --max-time 120 -u "$U:$T" \
  "$J/job/$PROJ/job/main/$BUILD/consoleText" 2>/dev/null)

[ -z "$CONSOLE" ] && { echo "  ⚠️ console vazio"; exit 2; }

echo "== RESUMO DA SUITE =="
echo "$CONSOLE" | grep -E 'Test Files|Tests +[0-9]+ (passed|failed)' | tail -6 | sed 's/^/  /'

echo
echo "== ARQUIVOS COM FALHA =="
# `FAIL` do vitest, e o cabecalho `❯ tests/...` que ele imprime por arquivo.
echo "$CONSOLE" | grep -E 'FAIL|failed\)' | grep -E 'tests?/' | sort -u | tail -15 | sed 's/^/  /'

echo
echo "== A ASSERCAO QUE QUEBROU =="
# O bloco do vitest tras `AssertionError`, `expected`/`received` e a linha.
echo "$CONSOLE" \
  | grep -E 'AssertionError|Error:|expected |→ |at .*tests/' \
  | grep -vE 'node_modules|^\s*$' \
  | tail -25 | cut -c1-170 | sed 's/^/  /'

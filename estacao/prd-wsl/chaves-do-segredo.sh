#!/usr/bin/env bash
# Lista as chaves de um Secret que casam com um prefixo (sem mostrar valor).
#     bash chaves-do-segredo.sh <ns> <secret> <prefixo>
set -uo pipefail
kubectl get secret "$2" -n "$1" -o json 2>/dev/null \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
alvo = '$3'.upper()
for k in sorted((d.get('data') or {}).keys()):
    if alvo in k.upper():
        print('    ' + k)
"

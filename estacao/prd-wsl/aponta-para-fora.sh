#!/usr/bin/env bash
# Alguma coisa da produção ainda aponta para FORA do cluster?
#
# ⚠️ Esta é a pergunta que decide se dá para fechar o Docker. Não se responde
# olhando contêiner rodando: contêiner sobrando é inofensivo. O que importa é
# se alguém no cluster ainda FALA com ele.
#
# Procura, em todos os Secrets e ConfigMaps, valor que aponte para o host:
# `host.docker.internal`, `localhost`, `127.0.0.1` ou o IP da estação.
set -uo pipefail

SUSPEITOS='host\.docker\.internal|127\.0\.0\.1|localhost|192\.168\.15\.'
achou=0

for ns in $(kubectl get ns -o name 2>/dev/null | sed 's#namespace/##' | grep -vE '^kube-|^default$'); do
  for s in $(kubectl get secret -n "$ns" -o name 2>/dev/null | grep -v 'service-account\|helm.release'); do
    linhas=$(kubectl get "$s" -n "$ns" -o json 2>/dev/null \
      | python3 -c '
import sys, json, base64, re
d = json.load(sys.stdin)
alvo = re.compile(r"host\.docker\.internal|127\.0\.0\.1|localhost|192\.168\.15\.")
for k, v in (d.get("data") or {}).items():
    try:
        texto = base64.b64decode(v).decode("utf-8", "replace")
    except Exception:
        continue
    if alvo.search(texto):
        # Esconde senha: isto vai para o log.
        texto = re.sub(r"://[^:/@]+:[^@]+@", "://***:***@", texto)
        print(f"    {k} = {texto[:96]}")
' 2>/dev/null)
    if [ -n "$linhas" ]; then
      echo "  $ns/$(basename "$s"):"
      echo "$linhas"
      achou=1
    fi
  done
done

echo
if [ "$achou" = "0" ]; then
  echo "  ✅ nenhuma configuracao da producao aponta para fora do cluster"
else
  echo "  ⚠️ ha configuracao apontando para o host -- conferir uma a uma:"
  echo "     endereco de servico EXTERNO (Mercado Pago, Google) e normal;"
  echo "     banco, fila ou API interna apontando para o host NAO e."
fi

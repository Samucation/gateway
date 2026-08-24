#!/usr/bin/env bash
# As chaves do sigma-financeiro existem nos Secrets da HOMOLOGAÇÃO?
#
# ⚠️ Em ARQUIVO. Inline dentro de `wsl.exe -- bash -c "..."` o `$ns` do laço é
# comido pelo shell do Windows: o comando roda com o namespace VAZIO e o erro
# que sai é um traceback de JSON, que não tem nada a ver com a causa.
set -uo pipefail
# ⚠️ ARRAY, e não string. `K="kubectl --kubeconfig=..."` com `"$K"` vira UM
# comando chamado "kubectl --kubeconfig=..." e o shell responde "não encontrado"
# -- que aqui aparecia como "não consegui ler o Secret", mandando procurar
# permissão e nome de objeto quando o problema era aspas.
K=(kubectl --kubeconfig=/var/lib/jenkins/.kube/config-hmg)

for ns in opuschat plataforma; do
  echo "  == $ns (hmg) =="
  "${K[@]}" get secret "${ns}-secrets" -n "$ns" -o json 2>/dev/null > /tmp/seg-$ns.json || true
  if [ ! -s /tmp/seg-$ns.json ]; then
    echo "    (nao consegui ler o Secret ${ns}-secrets)"
    continue
  fi
  python3 - "/tmp/seg-$ns.json" <<'FIM'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
ks = sorted(k for k in (d.get("data") or {}) if "SIGMA" in k.upper())
print("    " + (", ".join(ks) if ks else "(nenhuma chave SIGMA)"))
FIM
  rm -f "/tmp/seg-$ns.json"
done

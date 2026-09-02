#!/usr/bin/env bash
# O estado de CADA estagio do ultimo build — quem passou, quem falhou, quem
# esta esperando gente.
#
#     bash estado-dos-estagios.sh <projeto>
#
# ⚠️ Existe porque "FAILURE" na lista de builds NAO distingue duas coisas muito
# diferentes:
#
#   • o codigo quebrou           → tem conserto para fazer
#   • ninguem aprovou a promocao → o pipeline esta esperando um clique
#
# O segundo caso vira FAILURE por TIMEOUT depois de 1h, e na lista fica
# identico ao primeiro. Quem olha a lista conclui "a esteira esta quebrada" e
# vai procurar um defeito que nao existe.
set -uo pipefail

J=http://127.0.0.1:8080
U=samuca
T=$(tr -d '\r\n' < /var/lib/jenkins/secrets/api-token 2>/dev/null)
[ -z "$T" ] && { echo "  ⚠️ sem token em /var/lib/jenkins/secrets/api-token"; exit 3; }

PROJ=${1:?informe o projeto}
BUILD=${2:-lastBuild}

JSON=$(curl -s --max-time 90 -u "$U:$T" \
  "$J/job/$PROJ/job/main/$BUILD/wfapi/describe" 2>/dev/null)

[ -z "$JSON" ] && { echo "  ⚠️ sem resposta do wfapi (plugin ausente ou build inexistente)"; exit 2; }

# Sem jq na distro: o python3 do sistema resolve, e sem dependencia nova.
python3 - "$JSON" <<'PY'
import json, sys

try:
    d = json.loads(sys.argv[1])
except Exception as e:
    print("  ⚠️ resposta nao e JSON:", e); raise SystemExit(2)

print(f"  build #{d.get('id')}  {d.get('status')}  ({round(d.get('durationMillis',0)/60000)} min)")
print()
simbolo = {
    "SUCCESS": "✅", "FAILED": "❌", "ABORTED": "⏹", "UNSTABLE": "⚠️",
    "IN_PROGRESS": "⏳", "NOT_EXECUTED": "·", "PAUSED_PENDING_INPUT": "✋",
}
for s in d.get("stages", []):
    st = s.get("status", "?")
    seg = round(s.get("durationMillis", 0) / 1000)
    print(f"  {simbolo.get(st,'?')} {s.get('name','?'):<32} {st:<22} {seg:>5}s")

# ⚠️ A leitura que importa: se TODO estagio tecnico passou e o unico problema
# foi o portao humano, nao ha conserto de codigo a fazer.
tecnicos = [s for s in d.get("stages", [])
            if s.get("name") not in ("Promover para producao?", "Declarative: Post Actions")]
falhos = [s for s in tecnicos if s.get("status") in ("FAILED", "UNSTABLE")]
print()
if falhos:
    print("  ⛔ estagio(s) TECNICO(s) com problema — ha conserto a fazer:")
    for s in falhos:
        print(f"     • {s['name']}")
else:
    print("  ✅ nenhum estagio tecnico falhou.")
    print("     Se o build esta vermelho, foi o portao humano (aprovacao) ou o post.")
PY

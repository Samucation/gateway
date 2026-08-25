#!/usr/bin/env bash
# Onde a cadeia de voz do Urupix corta.
#
#   urupix-app  ->  central-motor (3300)  ->  Kokoro / Chatterbox / Whisper
#
# ⚠️ A mensagem do painel ("o motor de voz pode estar fora do ar") acusa a
# ÚLTIMA perna. Ela é idêntica quando o motor está de pé e é ELE que não tem
# para onde ir -- que é configuração, não GPU.
#
# 🐞 E não dá para medir com `kubectl exec ... curl`: imagem enxuta não tem
# `curl`, o comando falha, e o resultado sai `000` -- que se lê como "não
# alcança" e é "não tenho a ferramenta". Aqui quem mede é um Pod avulso com
# `curl` dentro, no MESMO namespace.
set -uo pipefail

medir() { # <rotulo> <url>
  local c
  c=$(kubectl run sonda-$RANDOM -n "$3" --rm -i --restart=Never \
        --image=curlimages/curl:8.10.1 --quiet -- \
        -s -o /dev/null -w '%{http_code}' --max-time 8 "$2" 2>/dev/null | tr -d '\r')
  # 404/405 contam como VIVO: respondeu, só não tem rota em `/`.
  local nota="responde"
  [ "${c:-000}" = "000" ] && nota="❌ nao alcanca"
  printf '  %-44s %s  %s\n' "$1" "${c:-000}" "$nota"
}

echo "== 1. o motor da Central de IA responde? =="
medir "central-motor:3300/health" "http://central-motor.central-ia.svc.cluster.local:3300/health" urupix

echo
echo "== 2. o motor sabe para ONDE mandar? =="
motor=$(kubectl get pods -n central-ia -l app=central-motor --no-headers 2>/dev/null | grep ' Running ' | head -1 | awk '{print $1}')
for v in KOKORO_URL CHATTERBOX_URL WHISPER_URL OLLAMA_URL; do
  val=$(kubectl exec -n central-ia "$motor" -- printenv "$v" 2>/dev/null | tr -d '\r')
  printf '  %-16s %s\n' "$v" "${val:-(VAZIA)}"
done

echo
echo "== 3. os motores de audio, de dentro do cluster =="
medir "kokoro.estacao:8880"     "http://kokoro.estacao.svc.cluster.local:8880/"     central-ia
medir "chatterbox.estacao:8004" "http://chatterbox.estacao.svc.cluster.local:8004/" central-ia
medir "whisper.estacao:8040"    "http://whisper.estacao.svc.cluster.local:8040/"    central-ia

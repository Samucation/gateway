#!/usr/bin/env bash
# O mesmo teste de voz, no cluster de HOMOLOGAÇÃO.
#
# Os dois ambientes compartilham o motor de áudio; o que muda é quem chama.
set -uo pipefail
K=(kubectl --kubeconfig=/var/lib/jenkins/.kube/config-hmg)

motor=$("${K[@]}" get pods -n central-ia -l app=central-motor --no-headers 2>/dev/null | grep ' Running ' | head -1 | awk '{print $1}')
echo "== o motor de hmg sabe para onde mandar? =="
for v in KOKORO_URL CHATTERBOX_URL; do
  val=$("${K[@]}" exec -n central-ia "$motor" -- printenv "$v" 2>/dev/null | tr -d '\r')
  printf '  %-16s %s\n' "$v" "${val:-(VAZIA)}"
done

CHAVE=$("${K[@]}" get secret urupix-secrets -n urupix -o jsonpath='{.data.CENTRAL_CHAVE}' 2>/dev/null | base64 -d)
[ -n "$CHAVE" ] || { echo "  (sem CENTRAL_CHAVE em hmg -- pulando o teste de audio)"; exit 0; }

echo
echo "== gerando audio em homologacao =="
saida=$("${K[@]}" run vozhmg$RANDOM -n urupix --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --quiet -- \
  -s -o /tmp/fala.ogg -w '%{http_code} %{size_download} %{content_type}' --max-time 90 \
  -X POST "http://central-motor.central-ia.svc.cluster.local:3300/v1/audio/speech" \
  -H "Authorization: Bearer $CHAVE" -H 'Content-Type: application/json' \
  -d '{"model":"kokoro","voice":"pf_dora","input":"teste de voz da homologacao"}' 2>/dev/null | tr -d '\r')
echo "  codigo: $(echo "$saida" | awk '{print $1}')   bytes: $(echo "$saida" | awk '{print $2}')   tipo: $(echo "$saida" | awk '{print $3}')"

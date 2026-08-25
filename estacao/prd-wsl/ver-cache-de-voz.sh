#!/usr/bin/env bash
# O que está no cache de voz, e algum arquivo parece TRUNCADO?
#
# 🐞 `voice-engine.ts` grava com `writeFile` direto no caminho final, e a
# decisão de reaproveitar é `existsSync(filePath)`. Se o processo morrer no meio
# da gravação — e este Pod passou horas sendo morto pela probe — sobra um mp3
# PELA METADE com o nome certo.
#
# ⚠️ A partir daí o defeito é PERMANENTE: o hash bate, o cache responde, e a
# mesma frase sai cortada para sempre. Não há erro em lugar nenhum; o arquivo
# existe e é servido com 200.
set -uo pipefail
pod=$(kubectl get pods -n urupix -l app=urupix-app --sort-by=.status.startTime --no-headers 2>/dev/null \
      | grep ' Running ' | tail -1 | awk '{print $1}')
[ -n "$pod" ] || { echo "  sem Pod"; exit 1; }

echo "  == arquivos no cache =="
kubectl exec -n urupix "$pod" -- sh -c 'ls -l /app/uploads/voice 2>/dev/null | tail -n +2' 2>/dev/null \
  | awk '{printf "    %8s bytes  %s\n", $5, $NF}'

echo
echo "  == suspeitos: mp3 pequeno demais para uma frase =="
# Uma frase curta em mp3 mono 24 kHz dá dezenas de KB. Menos de 8 KB é ou
# arquivo cortado, ou erro que o motor devolveu com cara de áudio.
kubectl exec -n urupix "$pod" -- sh -c \
  'find /app/uploads/voice -name "*.mp3" -size -8k 2>/dev/null' 2>/dev/null \
  | sed 's/^/    /' || true
echo "  (nada acima = nenhum suspeito)"

#!/usr/bin/env bash
# SOCORRO: dá ao Pod do Urupix um lugar gravável para o áudio sintetizado.
#
# 🐞 `voice-engine.ts` grava o mp3 em `/app/uploads/voice` antes de devolver a
# URL. O processo roda como `node` (uid 1000) e `/app` é do root: o `mkdir` dá
# `EACCES`, o `catch` devolve `null` e o overlay cai na voz do navegador.
#
# ⚠️ REMENDO, aplicado direto no cluster para a voz voltar hoje. O conserto de
# verdade está em `live-flow/k8s/base/app.yaml` e chega pela esteira — sem ele,
# o próximo `apply` desfaz isto em silêncio.
set -uo pipefail

kubectl patch deploy urupix-app -n urupix --type=json -p '[
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"audio-cache","emptyDir":{}}},
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"next-cache","emptyDir":{}}},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"audio-cache","mountPath":"/app/uploads"}},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"next-cache","mountPath":"/app/.next/cache"}}
]' >/dev/null

kubectl rollout status deploy/urupix-app -n urupix --timeout=420s | tail -1 | sed 's/^/  /'

echo "== o Pod consegue gravar agora? =="
pod=$(kubectl get pods -n urupix -l app=urupix-app --no-headers 2>/dev/null | grep ' Running ' | tail -1 | awk '{print $1}')
kubectl exec -n urupix "$pod" -- sh -c '
  mkdir -p /app/uploads/voice && echo ok > /app/uploads/voice/.t && rm -f /app/uploads/voice/.t \
    && echo "    ✅ grava" || echo "    ❌ ainda nao grava"
' 2>&1 | sed 's/^/  /'

#!/usr/bin/env bash
# Sobrou alguem em replicas=0 depois da partida escalonada?
#
#     wsl -d prd -- bash /mnt/e/.../prd-wsl/quem-ficou-zerado.sh
#
# ⚠️ Pod zerado NAO aparece em `get pods` -- ele nao existe. Um servico
# esquecido em zero fica invisivel justamente na tela onde as pessoas
# procuram problema, e so aparece quando alguem tenta usar.
set -uo pipefail

echo "== workloads em replicas=0 =="
kubectl get deploy,statefulset -A --no-headers \
  -o custom-columns=NS:.metadata.namespace,NOME:.metadata.name,DESEJADO:.spec.replicas,PRONTO:.status.readyReplicas \
  2>/dev/null | awk '$3=="0" {print "  ⚠️ " $1 "/" $2}'
echo "  (nada acima = ninguem zerado)"

echo
echo "== workloads com replicas pedidas mas NENHUMA pronta =="
kubectl get deploy,statefulset -A --no-headers \
  -o custom-columns=NS:.metadata.namespace,NOME:.metadata.name,DESEJADO:.spec.replicas,PRONTO:.status.readyReplicas \
  2>/dev/null | awk '$3!="0" && ($4=="<none>" || $4=="0") {print "  ❌ " $1 "/" $2 " (0/" $3 ")"}'
echo "  (nada acima = todos servindo)"

echo
echo "== Pods nao prontos =="
kubectl get pods -A --no-headers 2>/dev/null \
  | awk '{split($3,p,"/"); if (p[1]!=p[2] && $4!="Completed") print "  " $1 "/" $2 "  " $3 "  " $4}'
echo "  (nada acima = todos prontos)"

echo
echo "== resumo =="
kubectl get pods -A --no-headers 2>/dev/null \
  | awk '{split($3,p,"/"); if (p[1]==p[2] && p[1]>0) ok++; else if ($4!="Completed") nok++} END {print "  prontos: " ok+0 "   nao prontos: " nok+0}'

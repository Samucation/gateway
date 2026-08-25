#!/usr/bin/env bash
# O Pod do Urupix consegue GRAVAR o áudio que acabou de gerar?
#
# 🐞 `voice-engine.ts` sintetiza, faz `mkdir` + `writeFile` em
# `process.cwd()/uploads/voice` e devolve a URL. Se a gravação falhar, o
# `catch { return null }` engole o erro e a resposta sai SEM áudio -- e o
# overlay cai na voz do navegador.
#
# ⚠️ Ou seja: motor perfeito, áudio gerado, e o usuário ouve a "voz de
# segurança". O erro não aparece em lugar nenhum: foi capturado de propósito,
# para o alerta não sumir quando o motor cai.
set -uo pipefail
pod=$(kubectl get pods -n urupix -l app=urupix-app --sort-by=.status.startTime --no-headers 2>/dev/null \
      | grep ' Running ' | tail -1 | awk '{print $1}')
echo "  pod: ${pod:-nenhum}"
[ -n "$pod" ] || exit 1

echo
echo "== o sistema de arquivos e somente leitura? =="
kubectl get pod -n urupix "$pod" -o jsonpath='  readOnlyRootFilesystem={.spec.containers[0].securityContext.readOnlyRootFilesystem}{"\n"}' 2>/dev/null
echo "  volumes montados:"
kubectl get pod -n urupix "$pod" -o jsonpath='{range .spec.containers[0].volumeMounts[*]}    {.name} -> {.mountPath}{"\n"}{end}' 2>/dev/null

echo
echo "== teste de escrita no diretorio do audio =="
kubectl exec -n urupix "$pod" -- sh -c '
  D=/app/uploads/voice
  mkdir -p "$D" 2>&1 && echo "    mkdir ok" || echo "    ❌ mkdir FALHOU"
  echo teste > "$D/.escrita-teste" 2>&1 && echo "    escrita ok" || echo "    ❌ escrita FALHOU"
  rm -f "$D/.escrita-teste" 2>/dev/null
  echo "    conteudo atual: $(ls -1 "$D" 2>/dev/null | wc -l) arquivo(s)"
' 2>&1 | sed 's/^/  /'

echo
echo "== quem e o usuario do processo =="
kubectl exec -n urupix "$pod" -- sh -c 'id; ls -ld /app /app/uploads 2>/dev/null' 2>&1 | sed 's/^/    /'

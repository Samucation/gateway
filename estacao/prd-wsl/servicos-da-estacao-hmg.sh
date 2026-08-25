#!/usr/bin/env bash
# Os mesmos nomes do namespace `estacao`, agora no cluster de HOMOLOGAÇÃO.
#
# Motor de áudio é pesado e não se duplica por ambiente: enquanto os dois
# clusters estiverem na mesma máquina, produção e homologação apontam para o
# MESMO Kokoro e o MESMO Chatterbox. Para o manifesto ser idêntico nos dois, o
# NOME precisa existir nos dois — muda só para onde ele aponta.
#
# ⚠️ E o caminho aqui é diferente do da produção:
#
#     do k3s (distro WSL2)  ->  192.168.15.9      (IP da estação na rede)
#     do k3d (Docker)       ->  host.docker.internal
#
# Mesmo nome, caminhos diferentes — que é exatamente o que um Service sem
# seletor serve para esconder.
#
# 🐞 Aqui é `ExternalName`, e não `Endpoints` como na produção. `Endpoints`
# exige IP, e o que o k3d tem é NOME: `host.docker.internal` é resolvido pelo
# DNS do Docker Desktop (não está no `/etc/hosts` do nó — conferido). Fixar o
# número traria de volta o problema que derrubou a homologação antes: o
# endereço da máquina muda, e esta rede ainda não tem reserva de DHCP.
#
# ⚠️ `ExternalName` é só DNS: a porta do Service NÃO redireciona nada. Quem
# chama tem de usar a porta real na URL — e usa, porque a configuração das
# aplicações traz a porta junto.
set -uo pipefail
K=(kubectl --kubeconfig=/var/lib/jenkins/.kube/config-hmg)
DESTINO=${DESTINO_DA_ESTACAO:-host.docker.internal}

echo "  a estacao, vista do k3d: $DESTINO"
"${K[@]}" create namespace estacao --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null

for nome in kokoro chatterbox whisper sandbox-sigma; do
  # `--dry-run` + `apply` para poder rodar de novo sem erro de "já existe".
  cat <<YAML | "${K[@]}" apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: $nome
  namespace: estacao
  labels: { app.kubernetes.io/part-of: estacao }
spec:
  type: ExternalName
  externalName: $DESTINO
YAML
  echo "  $nome.estacao -> $DESTINO"
done

echo
echo "== conferindo pelo nome, de dentro do k3d =="
sonda() { # <rotulo> <url>
  local c
  c=$("${K[@]}" run sonda$RANDOM -n central-ia --rm -i --restart=Never \
      --image=curlimages/curl:8.10.1 --quiet -- \
      -s -o /dev/null -w '%{http_code}' --max-time 12 "$2" 2>/dev/null | tr -d '\r')
  printf '  %-40s %s\n' "$1" "${c:-000}"
}
sonda "kokoro      /health" "http://kokoro.estacao.svc.cluster.local:8880/health"
sonda "chatterbox  /"       "http://chatterbox.estacao.svc.cluster.local:8004/"
sonda "whisper     /health" "http://whisper.estacao.svc.cluster.local:8040/health"

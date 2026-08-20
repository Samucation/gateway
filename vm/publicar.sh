#!/usr/bin/env bash
# ===========================================================================
# Publica o Kong no cluster da maquina remota.
#
#     ./vm/publicar.sh
#
# Roda NA VM. Ele cria o ConfigMap a partir do kong.yml gerado, carimba o hash
# na anotacao do Pod e aplica.
#
# ⚠️ O hash e o que faz a configuracao ter efeito. O Kong le o arquivo na
# PARTIDA; sem trocar algo no Pod, um ConfigMap novo so muda o arquivo no disco
# e o Kong segue com o antigo -- e a pessoa jura que mudou a config (mudou) e
# nada aconteceu.
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")"

# `sudo` por padrao, porque rodando a mao na VM e o que funciona. Mas a esteira
# roda como o usuario `jenkins`, que ja esta no grupo `microk8s` e NAO tem sudo
# sem senha -- para ele, `sudo` travaria esperando uma senha que ninguem vai
# digitar, ate estourar o tempo limite do estagio. Dai o override:
#
#     KUBECTL='microk8s kubectl' ./vm/publicar.sh
K="${KUBECTL:-sudo microk8s kubectl}"

[ -f kong.yml ] || { echo "kong.yml nao existe. Rode: node vm/gerar-kong-vm.mjs"; exit 1; }

HASH=$(sha256sum kong.yml | cut -c1-12)
echo "==> kong.yml: $(wc -l < kong.yml) linhas, hash $HASH"

$K create namespace gateway --dry-run=client -o yaml | $K apply -f - >/dev/null

$K create configmap kong-config -n gateway --from-file=kong.yml=kong.yml \
  --dry-run=client -o yaml | $K apply -f - | sed 's/^/  /'

# Carimba o hash na anotacao antes de aplicar.
sed "s|gateway/config-hash: \".*\"|gateway/config-hash: \"$HASH\"|" k8s.yaml > /tmp/kong-k8s.yaml
$K apply -f /tmp/kong-k8s.yaml | sed 's/^/  /'
rm -f /tmp/kong-k8s.yaml

echo "==> aguardando ficar pronto"
$K rollout status deploy/kong -n gateway --timeout=180s | tail -1 | sed 's/^/  /'

#!/usr/bin/env bash
# Traduz `docker` para o nerdctl do containerd DO K3S.
#
# ⚠️ `--address` e `--namespace` sao obrigatorios: sem o primeiro o nerdctl
# procura o soquete no caminho padrao e diz "cannot access containerd socket";
# sem o segundo constroi num espaco que o k3s nao consulta, e o Pod sobe com
# `ErrImageNeverPull` depois de um build verde.
ARGS=(--address /run/k3s/containerd/containerd.sock --namespace k8s.io)

# 🐞 `--insecure-registry` no PUSH, e nao sempre.
#
# Os dois registros desta maquina falam HTTP puro: o da producao (localhost:32000)
# e o da homologacao (192.168.15.9:32001, publicado pelo Docker). `localhost` o
# nerdctl ja trata como inseguro sozinho; um endereco de REDE, nao -- ele tenta
# HTTPS e falha com
#
#     failed to do request: http: server gave HTTP response to HTTPS client
#
# que se le como registro fora do ar e e negociacao de protocolo.
#
# ⚠️ So no `push` e no `pull`. Ligar em tudo esconderia um dia em que um
# registro EXTERNO deixasse de ter TLS -- e ai HTTP puro seria mesmo um
# problema, com credencial trafegando em claro.
case "${1:-}" in
  push|pull) ARGS+=(--insecure-registry) ;;
esac

if [ "$(id -u)" -eq 0 ]; then
  exec /usr/local/bin/nerdctl "${ARGS[@]}" "$@"
fi
exec sudo -n /usr/local/bin/nerdctl "${ARGS[@]}" "$@"

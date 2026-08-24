#!/usr/bin/env bash
# Lista host + caminho -> Service:porta de cada Ingress do k3s.
#
# É o contraponto do `kong.yml`: o que o Traefik atende HOJE, e para ONDE. Antes
# de pôr o Kong na frente, todo host desta lista precisa existir lá também,
# apontando para o mesmo destino — senão a virada troca 200 por 404 em domínio
# que estava de pé.
set -uo pipefail
kubectl get ingress -A -o jsonpath='{range .items[*]}{$.metadata.namespace}{"|"}{range .spec.rules[*]}{.host}{"|"}{range .http.paths[*]}{.path}{"->"}{.backend.service.name}{":"}{.backend.service.port.number}{" "}{end}{"\n"}{end}{end}' \
  | sort -u | awk -F'|' '{printf "  %-44s %-16s %s\n", $2, $1, $3}'

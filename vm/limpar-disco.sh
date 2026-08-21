#!/usr/bin/env bash
# ===========================================================================
# Limpeza de disco da maquina de homologacao.
#
#     sudo /usr/local/sbin/limpar-disco.sh          # limpa
#     sudo /usr/local/sbin/limpar-disco.sh --seco   # so mostra o que faria
#
# Roda TODO DIA por cron. A limpeza semanal anterior era frouxa demais para a
# fase de construcao: medido em 20/08/2026, um unico dia de trabalho gerou
# 8,4 GB de cache de build.
#
# ---------------------------------------------------------------------------
# POR QUE DISCO CHEIO E PIOR AQUI DO QUE PARECE
# ---------------------------------------------------------------------------
# Num Kubernetes, disco cheio nao da "sem espaco". O kubelet passa a DESPEJAR
# Pods sozinho para liberar espaco, e a mensagem diz que o Pod foi removido --
# nao que acabou o disco. Perde-se um dia cacando problema de aplicacao que e
# de armazenamento.
#
# ---------------------------------------------------------------------------
# OS TRES CONSUMIDORES, em ordem de tamanho
# ---------------------------------------------------------------------------
#   1. cache de build do Docker  -- 8,4 GB, e 100% descartavel depois do push
#   2. imagens locais do Docker  -- copia do que ja esta no registro
#   3. o REGISTRO do cluster     -- guarda TODA tag empurrada, para sempre
#
# O terceiro e o que ninguem lembra: apagar imagem do Docker nao mexe nele.
# ===========================================================================
set -euo pipefail

SECO=0
[ "${1:-}" = "--seco" ] && SECO=1

REG=localhost:32000

# 🐞 Os tipos de manifesto que o registro pode devolver.
#
# So `application/vnd.docker.distribution.manifest.v2+json` NAO BASTA: o
# BuildKit (que e o que o `docker build` usa hoje) empurra manifesto no formato
# OCI. Com o cabecalho antigo, o registro devolvia
#
#     HTTP/1.1 404 Not Found
#
# para uma tag que ESTAVA na listagem -- o que lia como "a tag sumiu", quando
# era so o formato pedido nao bater com o guardado.
ACEITA="application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json"
antes=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')

log(){ echo "[limpar-disco] $*"; }
faz(){ if [ "$SECO" = "1" ]; then log "(seco) $*"; else eval "$@"; fi; }

log "disco antes: ${antes}G livres"

# ---------------------------------------------------------------------------
# 1. Cache de build — INTEIRO, sem filtro de idade.
#
# Ele nao serve para nada depois que a imagem foi empurrada: o cluster puxa do
# registro, nao daqui. Guardar cache "por via das duvidas" e trocar 8 GB por
# alguns minutos de build que talvez nunca aconteca.
# ---------------------------------------------------------------------------
log "cache de build:"
if [ "$SECO" = "1" ]; then
  docker system df 2>/dev/null | grep -i "build cache" | sed 's/^/  /'
else
  docker builder prune -af 2>/dev/null | tail -1 | sed 's/^/  /'
fi

# ---------------------------------------------------------------------------
# 2. Imagens locais que nao estao em uso.
#
# 🐞 SEM FILTRO DE IDADE. Ele estava em `--filter until=24h`, e isso deixou
# escapar 14,8 GB.
#
# O raciocinio original parecia bom: "guardar as de hoje, que ainda servem de
# cache". Mas num dia de trabalho TODAS as imagens tem menos de 24 horas -- o
# filtro protegia justamente aquelas que enchiam o disco, e a limpeza diaria
# reportava sucesso sem liberar quase nada.
#
# Isso terminou num incidente real em 21/08/2026: o disco chegou a 97%, o
# kubelet marcou o no com `disk-pressure` e DESPEJOU sete Pods -- Grafana,
# Loki, Prometheus, dois Keycloak, o rembg e o proprio SonarQube. Rodar
# `docker image prune -af` sem filtro liberou 14,8 GB de uma vez.
#
# A imagem util ja esta no REGISTRO do cluster; a copia local do Docker e
# descartavel depois do push. Quem quiser cache de camada tem o `builder
# prune --keep-storage`, que poe teto de TAMANHO -- que e o que importa aqui.
# ---------------------------------------------------------------------------
log "imagens locais:"
faz "docker image prune -af 2>/dev/null | tail -1 | sed 's/^/  /'"

# ---------------------------------------------------------------------------
# 3. O REGISTRO do cluster.
#
# ⚠️ Este e o que cresce calado. Cada build empurra uma tag nova e NENHUMA sai.
# Medido: 23 tags, 2 GB -- com o `veltrixa-api` sozinho guardando 6 versoes.
#
# A regra: guardar a tag EM USO e a anterior. A anterior existe para voltar
# versao sem reconstruir; da terceira em diante e so peso.
#
# `REGISTRY_STORAGE_DELETE_ENABLED=yes` ja esta ligado neste registro
# (conferido), entao o DELETE funciona. Sem isso ele devolveria 405.
# ---------------------------------------------------------------------------
log "registro do cluster:"

EM_USO=$(microk8s kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' 2>/dev/null \
         | tr ' ' '\n' | grep "^$REG/" | sort -u)

for repo in $(curl -s http://$REG/v2/_catalog | tr ',' '\n' | tr -d '{}[]"' | sed 's/repositories://' | grep -v '^$'); do
  # As tags vem sem ordem garantida; ordenar por nome funciona porque elas sao
  # carimbos de tempo (AAAAMMDD-HHMM).
  tags=$(curl -s "http://$REG/v2/$repo/tags/list" | tr ',' '\n' | grep -oE '[0-9]{8}-[0-9]{4}' | sort -r || true)
  [ -z "$tags" ] && continue

  # 🐞 `|| true` em TODO grep daqui.
  #
  # Com `set -e`, um grep que nao acha nada sai com codigo 1 e MATA o script.
  # E "nao achar nada" e o caso NORMAL: repositorio com so a tag em uso faz o
  # `grep -v` devolver vazio.
  #
  # O script morria em silencio no PRIMEIRO repositorio, e a saida terminava
  # em "registro do cluster:" sem mais nada -- o que lia como "nao havia o que
  # apagar", quando era o script tendo morrido.
  guardar=""
  # a que esta rodando
  usada=$(echo "$EM_USO" | grep "^$REG/$repo:" | sed "s|.*:||" | head -1 || true)
  [ -n "$usada" ] && guardar="$usada"
  # e a mais recente que nao seja ela (para voltar versao)
  anterior=$(echo "$tags" | grep -v "^${usada:-__nada__}$" | head -1 || true)
  [ -n "$anterior" ] && guardar="$guardar $anterior"

  for t in $tags; do
    if echo " $guardar " | grep -q " $t "; then continue; fi
    # 🐞 DUAS coisas erradas aqui na primeira versao:
    #
    # 1. `curl -sI` (HEAD) nao trouxe o `Docker-Content-Digest` deste
    #    registro. `-o /dev/null -D -` faz um GET e imprime so os cabecalhos,
    #    e ai o digest vem.
    #
    # 2. sem `|| true`, um grep que nao acha nada DENTRO de uma atribuicao
    #    mata o script: `pipefail` faz a atribuicao falhar e `set -e` encerra.
    #    Era exatamente o que acontecia -- morria no primeiro digest vazio, e
    #    a saida terminava em 'registro do cluster:' sem explicacao.
    dig=$(curl -sS -o /dev/null -D - \
          -H "Accept: $ACEITA" \
          "http://$REG/v2/$repo/manifests/$t" 2>/dev/null \
          | grep -i '^docker-content-digest:' | tr -d '' | awk '{print $2}' || true)
    [ -z "$dig" ] && continue
    if [ "$SECO" = "1" ]; then
      log "  (seco) apagaria $repo:$t"
    else
      curl -sS -X DELETE "http://$REG/v2/$repo/manifests/$dig" >/dev/null 2>&1 && log "  apagada $repo:$t"
    fi
  done
done

# ⚠️ Apagar a tag NAO libera espaco. O registro so marca o manifesto como
# removido; quem apaga os blobs e o coletor. Sem este passo, a limpeza acima
# nao muda um byte no disco -- e a pessoa jura que limpou (limpou) e nada mudou.
if [ "$SECO" = "0" ]; then
  log "coletando os blobs orfaos do registro:"
  POD=$(microk8s kubectl get pods -n container-registry -l app=registry -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$POD" ]; then
    microk8s kubectl exec -n container-registry "$POD" -- \
      bin/registry garbage-collect --delete-untagged /etc/docker/registry/config.yml 2>/dev/null \
      | tail -2 | sed 's/^/  /' || log "  (o coletor nao rodou -- conferir a imagem do registro)"
  fi
fi

# ---------------------------------------------------------------------------
# 4. IMAGENS DO CONTAINERD que nenhum Pod referencia.
#
# Este e o MAIOR consumidor, e faltava aqui. Medido em 21/08/2026: 6,2 GB, e o
# disco caiu de 88% para 77% num passo so.
#
# ⚠️ E o containerd, e NAO o Docker. Sao dois armazens diferentes na mesma
# maquina: o Docker constroi as imagens, o containerd e quem o Kubernetes usa
# para RODAR. Limpar um nao toca no outro -- e os passos 1 a 3 acima so
# mexiam no Docker.
#
# 🐞 As duas listas TEM que estar ordenadas antes do `comm`.
#
# A primeira versao disto, rodada a mao, comparou listas fora de ordem. O
# `comm` avisou ("file 1 is not in sorted order") mas seguiu, e o resultado
# incluiu `postgres:16-alpine`, `kafka:3.8.0` e `kong:3.8` -- imagens EM USO.
# Elas foram removidas. Nada caiu na hora, porque o conteiner em execucao
# segura as proprias camadas, mas qualquer reinicio passaria a exigir download
# de novo. Foi sorte, nao cuidado.
# ---------------------------------------------------------------------------
if [ "$SECO" = "0" ]; then
  log "imagens do containerd sem Pod que as referencie:"

  microk8s kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
    | grep -v '^$' | sort -u > /tmp/limpar-em-uso.txt

  microk8s ctr --namespace k8s.io images ls -q 2>/dev/null \
    | grep -v '^sha256:' | sort -u > /tmp/limpar-no-disco.txt

  # `pause` fica de fora sempre: e a imagem que sustenta TODO Pod, e nao
  # aparece em `spec.containers` de ninguem.
  n=0
  while read -r img; do
    [ -z "$img" ] && continue
    case "$img" in *pause*) continue ;; esac
    microk8s ctr --namespace k8s.io images rm "$img" >/dev/null 2>&1 && n=$((n + 1))
  done < <(comm -13 /tmp/limpar-em-uso.txt /tmp/limpar-no-disco.txt)

  log "  $n imagem(ns) removida(s)"
  rm -f /tmp/limpar-em-uso.txt /tmp/limpar-no-disco.txt
fi

depois=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
log "disco depois: ${depois}G livres  (ganho: $((depois - antes))G)"

# ---------------------------------------------------------------------------
# Aviso quando ainda esta apertado.
#
# O kubelet comeca a despejar Pod por volta de 10% livre. 15% e o ponto de
# avisar, nao de agir -- agir sozinho apagando mais seria arriscar apagar o que
# importa.
# ---------------------------------------------------------------------------
pct=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ "$pct" -ge 85 ]; then
  log "⚠️ disco em ${pct}% mesmo depois da limpeza."
  log "   O kubelet despeja Pods por volta de 90%, e a mensagem NAO menciona disco."
  log "   Considere aumentar o disco da VM (a conta original pedia ~100 GB)."
fi

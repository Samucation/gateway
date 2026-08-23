#!/usr/bin/env bash
# ===========================================================================
# Sobe as aplicacoes na producao local (k3s da distro `prd`).
#
#     bash subir-apps.sh                 # todos
#     bash subir-apps.sh sigma-financeiro  # so um
#
# Constroi a imagem com o atalho `docker` (nerdctl -> containerd do k3s),
# carimba a tag no overlay `prd` e aplica.
# ===========================================================================
#
# ⚠️ ISTO NAO SUBSTITUI A ESTEIRA. E o caminho de PARTIDA, para o ambiente
# existir antes de haver Jenkins com o que trabalhar. Depois de tudo de pe,
# quem implanta e a esteira -- ela e a unica que sabe qual tag acabou de
# construir, e aplicar overlay a mao ja derrubou quatro servicos em 22/08.
set -uo pipefail

REPOS=/mnt/e/Desenvolvimento/Dev/Workspace
TRABALHO=/raiz
REG=localhost:32000

# projeto | namespace | imagem:argumentos-do-build (separados por ;)
LISTA=$(cat <<'FIM'
sigma-financeiro|sigma-financeiro|sigma-financeiro:-t REG/sigma-financeiro:TAG .
sprinklegames-portal|sprinklegames|sprinklegames-portal:-t REG/sprinklegames-portal:TAG .
live-flow|urupix|urupix:-t REG/urupix:TAG .
opuschat|opuschat|opuschat:-t REG/opuschat:TAG .
cafe-mobile-erp|plataforma|plataforma:-t REG/plataforma:TAG .
central-ia|central-ia|central-motor:-t REG/central-motor:TAG .;central-portal:-t REG/central-portal:TAG ./_portal
sigma-midia|sigma-midia|sigma-midia:-t REG/sigma-midia:TAG .;sigma-midia-portal:-t REG/sigma-midia-portal:TAG ./portal
system-api|veltrixa|veltrixa-api:-t REG/veltrixa-api:TAG .;veltrixa-frontend:-t REG/veltrixa-frontend:TAG ./frontend;veltrixa-storefront:-t REG/veltrixa-storefront:TAG ./storefront;veltrixa-nfe:-t REG/veltrixa-nfe:TAG ./nfe-service
FIM
)

alvo="${1:-}"
falhas=0

echo "== subindo as aplicacoes na producao local =="
mkdir -p "$TRABALHO"

# 🐞 A LISTA VAI PELO DESCRITOR 3, E NAO PELA ENTRADA PADRAO.
#
# `docker build` e `kubectl apply` chamados DENTRO do laco consomem a entrada
# padrao -- e levam junto o resto da lista. O sintoma e mudo: o script sobe o
# PRIMEIRO projeto, imprime o resumo e encerra, como se so houvesse um.
#
# O mesmo defeito estava no `migrar-dados.sh` e me custou uma rodada inteira
# procurando erro no filtro de projeto.
while IFS='|' read -r proj ns imagens <&3; do
  [ -n "$proj" ] || continue
  [ -z "$alvo" ] || [ "$alvo" = "$proj" ] || continue

  echo ""
  echo "--- $proj (namespace $ns) ---"

  # ⚠️ CLONE, e nao build direto de /mnt/e.
  #
  # 🐞 O sistema de arquivos do Windows visto pelo WSL (9p) e lento a ponto de
  # mudar a natureza do problema: um `npm ci` que leva 40 s no ext4 passa de
  # dez minutos ali, e parece build travado. Alem disso o clone entrega o
  # estado COMMITADO -- que e o que a esteira publicaria, e nao o que estiver
  # meio editado na area de trabalho.
  destino="$TRABALHO/$proj"
  if [ -d "$destino/.git" ]; then
    git -C "$destino" fetch -q origin 2>/dev/null
    git -C "$destino" reset -q --hard origin/main 2>/dev/null || git -C "$destino" reset -q --hard
  else
    git clone -q "$REPOS/$proj" "$destino" || { echo "  ERRO: nao clonei $proj"; falhas=$((falhas+1)); continue; }
  fi

  tag=$(git -C "$destino" rev-parse --short=12 HEAD)
  echo "  tag: $tag"

  ok=1
  IFS=';' read -ra partes <<< "$imagens"
  for parte in "${partes[@]}"; do
    nome="${parte%%:*}"
    args="${parte#*:}"
    args="${args//REG/$REG}"
    args="${args//TAG/$tag}"
    echo "  construindo $nome..."
    # shellcheck disable=SC2086
    if ! (cd "$destino" && docker build -q $args >/dev/null 2>/tmp/build-$nome.log); then
      echo "  ERRO ao construir $nome:"
      tail -5 "/tmp/build-$nome.log" | sed 's/^/      /'
      ok=0
    fi
  done
  [ "$ok" = 1 ] || { falhas=$((falhas+1)); continue; }

  K="$destino/k8s/overlays/prd/kustomization.yaml"
  if [ ! -f "$K" ]; then
    echo "  SEM overlay prd -- pulando"
    falhas=$((falhas+1)); continue
  fi
  # A mesma substituicao que a esteira faz.
  sed -i "s|newTag: .*|newTag: \"$tag\"|" "$K"

  echo "  aplicando..."
  if ! kubectl apply -k "$destino/k8s/overlays/prd" >/tmp/apply-$proj.log 2>&1; then
    echo "  ERRO ao aplicar:"
    tail -6 "/tmp/apply-$proj.log" | sed 's/^/      /'
    falhas=$((falhas+1)); continue
  fi

  # ⚠️ `apply` devolve zero antes de a versao subir -- a mesma licao da
  # esteira. Sem esperar, um Pod em CrashLoopBackOff passaria por sucesso.
  echo "  esperando ficar de pe..."
  for r in $(kubectl get deploy,statefulset -n "$ns" -o name 2>/dev/null); do
    kubectl rollout status -n "$ns" "$r" --timeout=300s 2>&1 | tail -1 | sed 's/^/      /'
  done
done 3<<< "$LISTA"

echo ""
echo "== resultado =="
kubectl get pods -A --no-headers 2>/dev/null | awk '{print $1}' | sort | uniq -c | sed 's/^/  /'
echo "  falhas: $falhas"
exit "$falhas"

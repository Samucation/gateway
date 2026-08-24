#!/usr/bin/env bash
# ===========================================================================
# Confere, host a host, se o KONG responde o mesmo que o TRAEFIK respondia.
#
#     bash conferir-kong.sh                 # lado a lado: Kong (8050) x Traefik (80)
#     bash conferir-kong.sh --gravar-base   # grava o que o Traefik responde HOJE
#     bash conferir-kong.sh --pela-entrada  # compara a porta 80 com a base gravada
#
# É a conferência que autoriza (ou não) virar a entrada da produção.
#
# ---------------------------------------------------------------------------
# ⚠️ POR QUE NÃO BASTA COMPARAR O CÓDIGO HTTP
# ---------------------------------------------------------------------------
# Dois apps diferentes respondem 200 no mesmo domínio. Foi o que quase
# aconteceu com `opuschat.cursodetecnologia.dev.br`: o kong.yml mandava para
# `plataforma-app` e o cluster serve de `opuschat-app`. Uma conferência por
# código passaria, e o domínio passaria a servir OUTRO PRODUTO.
#
# Então compara-se também o TAMANHO e o <title> do corpo. E, para os hosts
# declarados, exige-se `X-Request-Id` na resposta: é a prova de que a rota
# própria pegou a requisição, e não a rota de reserva, que só repassa.
#
# ---------------------------------------------------------------------------
# 🐞 POR QUE EXISTE O MODO `--gravar-base`
# ---------------------------------------------------------------------------
# Depois que o Kong assume a porta 80, comparar "8050 contra 80" compara o Kong
# com ele mesmo — e passa sempre, inclusive se tudo estiver errado. A base tem
# de ser gravada ANTES da troca, com o Traefik ainda atendendo.
# ===========================================================================
set -uo pipefail

KONG=${KONG_URL:-http://127.0.0.1:8050}
TRAEFIK=${TRAEFIK_URL:-http://127.0.0.1:80}
BASE=${BASE_ARQ:-/var/tmp/kong-base-traefik.txt}

# Hosts declarados no kong.yml: têm rota própria e plugins.
DECLARADOS="urupix.com.br
www.urupix.com.br
urupix.cursodetecnologia.dev.br
sigma-midia.cursodetecnologia.dev.br
sigma-financeiro.cursodetecnologia.dev.br
opuschat.cursodetecnologia.dev.br
cafe-api.cursodetecnologia.dev.br
central-ia.cursodetecnologia.dev.br"

# Hosts que o Kong NÃO declara: têm de sair pela reserva, para o Traefik,
# respondendo igualzinho ao que respondem hoje.
RESERVA="veltrixa.cursodetecnologia.dev.br
ninjasystem.cursodetecnologia.dev.br
ninjasystem-admin.cursodetecnologia.dev.br
ninjasystem-auth.cursodetecnologia.dev.br
sprinklegames.com.br
www.sprinklegames.com.br
sigma-midia-arquivos.cursodetecnologia.dev.br
sonar.hmg"

falhou=0

medir() { # <destino> <host>  ->  "codigo|tamanho|titulo|temRequestId"
  local d="$1" h="$2" cab cod tam tit rid arq
  arq=$(mktemp)
  cab=$(curl -s -D - -o "$arq" --max-time 15 -H "Host: $h" "$d/" 2>/dev/null)
  cod=$(printf '%s' "$cab" | grep -oE '^HTTP/[0-9.]+ [0-9]+' | tail -1 | grep -oE '[0-9]+$')
  rid=$(printf '%s' "$cab" | grep -ciE '^x-request-id:')
  tam=$(wc -c < "$arq" 2>/dev/null | tr -d ' ')
  tit=$(grep -aoiE '<title[^>]*>[^<]*' "$arq" 2>/dev/null | head -1 | sed 's/<[^>]*>//' | tr -d '\r\n|')
  rm -f "$arq"
  echo "${cod:-000}|${tam:-0}|${tit:0:28}|${rid:-0}"
}

julgar() { # <host> <medida-antes> <medida-depois> <exige-request-id>
  local h="$1" a="$2" b="$3" exige="$4"
  local ac=${a%%|*} bc=${b%%|*}
  local at bt ai bi rid dif nota
  at=$(echo "$a" | cut -d'|' -f2); bt=$(echo "$b" | cut -d'|' -f2)
  ai=$(echo "$a" | cut -d'|' -f3); bi=$(echo "$b" | cut -d'|' -f3)
  rid=$(echo "$b" | cut -d'|' -f4)
  nota="ok"

  # Código diferente é roteamento diferente. 404 pelo Kong é o host que ele
  # não reconheceu — o estrago clássico de virar gateway.
  [ "$ac" != "$bc" ] && { nota="CODIGO $ac->$bc"; falhou=1; }
  # Título diferente com os dois respondendo 200 é OUTRO APP atendendo.
  [ "$nota" = "ok" ] && [ "$ai" != "$bi" ] && { nota="CONTEUDO '$ai' -> '$bi'"; falhou=1; }
  # Tamanho: página dinâmica varia um pouco; 20% é folga com sobra.
  if [ "$nota" = "ok" ] && [ "$at" -gt 0 ] && [ "$bt" -gt 0 ]; then
    dif=$(( (at - bt) * 100 / at )); dif=${dif#-}
    [ "$dif" -gt 20 ] && { nota="TAMANHO $at -> $bt ($dif%)"; falhou=1; }
  fi
  if [ "$nota" = "ok" ] && [ "$exige" = "1" ] && [ "$rid" = "0" ]; then
    nota="SEM X-Request-Id (caiu na reserva, sem os plugins)"; falhou=1
  fi

  printf '  %-46s %s -> %s  %s\n' "$h" "$ac" "$bc" "$nota"
}

todos() { printf '%s\n%s\n' "$DECLARADOS" "$RESERVA"; }
exigencia() { # 1 para os declarados
  case "$1" in
    urupix.com.br|www.urupix.com.br|urupix.cursodetecnologia.dev.br) echo 1 ;;
    sigma-midia.cursodetecnologia.dev.br|sigma-financeiro.cursodetecnologia.dev.br) echo 1 ;;
    opuschat.cursodetecnologia.dev.br|cafe-api.cursodetecnologia.dev.br) echo 1 ;;
    central-ia.cursodetecnologia.dev.br) echo 1 ;;
    *) echo 0 ;;
  esac
}

case "${1:-}" in
  --gravar-base)
    : > "$BASE"
    echo "== gravando o que o Traefik responde HOJE ($TRAEFIK) =="
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      m=$(medir "$TRAEFIK" "$h")
      echo "$h|$m" >> "$BASE"
      printf '  %-46s %s\n' "$h" "$m"
    done <<< "$(todos)"
    echo "  base em $BASE"
    ;;

  --pela-entrada)
    [ -s "$BASE" ] || { echo "  ❌ sem base gravada em $BASE — rode --gravar-base ANTES de trocar"; exit 2; }
    echo "== porta 80 (a entrada de verdade) contra a base do Traefik =="
    while IFS='|' read -r h c t i r; do
      [ -n "$h" ] || continue
      julgar "$h" "$c|$t|$i|$r" "$(medir "$TRAEFIK" "$h")" "$(exigencia "$h")"
    done < "$BASE"
    ;;

  *)
    echo "== hosts declarados (rota propria + plugins) =="
    while IFS= read -r h; do
      [ -n "$h" ] && julgar "$h" "$(medir "$TRAEFIK" "$h")" "$(medir "$KONG" "$h")" 1
    done <<< "$DECLARADOS"
    echo
    echo "== hosts pela reserva (Kong repassa ao Traefik) =="
    while IFS= read -r h; do
      [ -n "$h" ] && julgar "$h" "$(medir "$TRAEFIK" "$h")" "$(medir "$KONG" "$h")" 0
    done <<< "$RESERVA"
    ;;
esac

echo
if [ "$falhou" = "0" ]; then
  echo "  ✅ nenhuma diferenca de resposta"
else
  echo "  ❌ ha diferenca — a producao boa e a de antes"
fi
exit "$falhou"

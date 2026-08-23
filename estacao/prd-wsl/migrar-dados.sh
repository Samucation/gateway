#!/usr/bin/env bash
# ===========================================================================
# Leva os DADOS de producao dos conteineres Docker para os Pods do k3s.
#
#     bash migrar-dados.sh                  # todos
#     bash migrar-dados.sh sigma_financeiro # so um banco
#     bash migrar-dados.sh --conferir       # so compara, nao copia
#
# ⚠️ RODA NO GIT BASH DO WINDOWS, e nao dentro da distro.
# ===========================================================================
#
# ⚠️ ESTE E O PASSO QUE MEXE COM DINHEIRO. Ele copia doacoes, cobrancas,
# cadastros e pedidos. Tudo aqui e escrito para falhar ALTO em vez de seguir
# em frente com metade.
#
# ---------------------------------------------------------------------------
# POR QUE ELE RODA DO LADO DE FORA
# ---------------------------------------------------------------------------
# A origem e o Docker Desktop; o destino e o k3s da distro `prd`. Nenhum dos
# dois enxerga o outro:
#
#   - dentro da distro, `docker` e o atalho para o nerdctl do k3s -- ele NAO
#     conhece os conteineres do Docker Desktop;
#   - no Windows nao ha `kubectl` apontado para o k3s.
#
# Cada lado e chamado de onde existe, e o arquivo intermediario mora num
# caminho que os DOIS enxergam (`E:` = `/mnt/e`).
#
# 🐞 E o dump NAO passa por cano entre os dois. `wsl.exe` no meio de um pipe
# binario corrompe o conteudo, e o estrago so aparece la na frente como
# "input file appears to be a text format dump".
#
# ---------------------------------------------------------------------------
# COMO ELE PROVA QUE DEU CERTO
# ---------------------------------------------------------------------------
# 🐞 A verificacao ingenua -- "o restore terminou sem erro" -- ja nos enganou
# duas vezes: contando TABELAS em vez de linhas (schema chega, dado nao), e
# confiando no codigo de saida, que mistura aviso com erro.
#
# Aqui a prova e a MESMA CONTAGEM dos dois lados, tabela a tabela, DEPOIS da
# copia. Diferenca em qualquer tabela reprova a migracao daquele banco.
set -uo pipefail

TMP_WIN=/e/Desenvolvimento/Dev/Workspace/_migracao
TMP_WSL=/mnt/e/Desenvolvimento/Dev/Workspace/_migracao
mkdir -p "$TMP_WIN"

# ⚠️ `tr -d` com NUL e CR nao e frescura: o `wsl.exe` devolve texto com bytes
# nulos, e sem limpar isso qualquer comparacao falha por diferenca invisivel.
LIMPAR="tr -d \\000\\r"

na_distro() {
  MSYS_NO_PATHCONV=1 wsl.exe -d prd -u root -- bash -c "$1" 2>/dev/null | tr -d '\000\r'
}
no_docker() {
  MSYS_NO_PATHCONV=1 docker "$@" 2>/dev/null
}

# conteiner-docker | usuario | banco | namespace | pod-do-k3s
LISTA=$(cat <<'FIM'
liveflow-db|liveflow|liveflow|urupix|urupix-postgres-0
sigma-db|sigma|sigma_financeiro|sigma-financeiro|sigma-db-0
sigma-db-sandbox|sigma|sigma_financeiro_sandbox|sigma-financeiro|sigma-db-sandbox-0
sprinklegames-postgres|sprinkle|sprinklegames|sprinklegames|sprinklegames-postgres-0
opuschat-db|plataforma|plataforma|opuschat|opuschat-postgres-0
plataforma-db|plataforma|plataforma|plataforma|plataforma-postgres-0
central-db-motor|central|central|central-ia|central-postgres-motor-0
central-db-portal|central|central_portal|central-ia|central-postgres-portal-0
sigma-midia-postgres|midia|sigma_midia|sigma-midia|sigma-midia-postgres-0
veltrixa-postgres|veltrixa|veltrixa_db|veltrixa|veltrixa-postgres-0
veltrixa-nfe-postgres|nfe|nfe_db|veltrixa|veltrixa-nfe-postgres-0
veltrixa-keycloak-postgres|keycloak|keycloak_db|veltrixa|veltrixa-keycloak-postgres-0
FIM
)

alvo="${1:-}"
so_conferir=0
if [ "$alvo" = "--conferir" ]; then so_conferir=1; alvo=""; fi

# ---------------------------------------------------------------------------
# A CONTAGEM QUE SERVE DE PROVA
# ---------------------------------------------------------------------------
# Linhas por tabela do schema `public`. E o retrato comparado antes e depois.
#
# ⚠️ Nao usa `reltuples` do catalogo: aquilo e ESTIMATIVA do planejador, pode
# estar horas desatualizada, e num banco de dinheiro estimativa nao prova nada.
cat > "$TMP_WIN/contagem.sql" <<'FIM'
SELECT string_agg(t || '=' || n, ',' ORDER BY t) FROM (
  SELECT c.relname AS t,
         (xpath('/row/c/text()',
                query_to_xml(format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname),
                             false, true, '')))[1]::text::bigint AS n
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r' AND n.nspname = 'public'
) x;
FIM

contar_docker() {
  no_docker exec -i "$1" psql -U "$2" -d "$3" -tAf - < "$TMP_WIN/contagem.sql" | head -1 | tr -d '\r'
}
contar_k3s() {
  na_distro "kubectl exec -i -n $1 $2 -- psql -U $3 -d $4 -tAf - < $TMP_WSL/contagem.sql | head -1"
}

falhas=0

# 🐞 A LISTA VAI PELO DESCRITOR 3, E NAO PELA ENTRADA PADRAO.
#
# Com `done <<< "$LISTA"`, o `wsl.exe` e o `docker` chamados DENTRO do laco
# consomem a entrada padrao -- e levam junto o resto da lista. O sintoma e
# silencioso e parece outra coisa: o script processa o PRIMEIRO banco, imprime
# "0 problemas" e encerra, como se so houvesse um a migrar.
#
# Perdi uma rodada inteira achando que a lista estava filtrada errado.
while IFS='|' read -r cont user base ns pod <&3; do
  [ -n "$cont" ] || continue
  if [ -n "$alvo" ] && [ "$alvo" != "$cont" ] && [ "$alvo" != "$base" ]; then continue; fi

  echo ""
  echo "--- $base  ($cont -> $ns/$pod) ---"

  if ! no_docker ps --format '{{.Names}}' | tr -d '\r' | grep -qx "$cont"; then
    echo "  origem ausente (conteiner $cont fora do ar) -- pulando"
    continue
  fi
  if ! na_distro "kubectl get pod $pod -n $ns -o name" | grep -q "$pod"; then
    echo "  destino ausente (pod $pod) -- pulando"
    continue
  fi

  antes=$(contar_docker "$cont" "$user" "$base")
  if [ -z "$antes" ]; then
    echo "  ⚠️ nao consegui contar a ORIGEM -- nao vou copiar as cegas"
    falhas=$((falhas+1)); continue
  fi

  if [ "$so_conferir" = "1" ]; then
    depois=$(contar_k3s "$ns" "$pod" "$user" "$base")
    if [ "$antes" = "$depois" ]; then
      echo "  ✅ iguais"
    else
      echo "  ❌ DIFERENTES"
      echo "     docker: ${antes:0:170}"
      echo "     k3s   : ${depois:0:170}"
      falhas=$((falhas+1))
    fi
    continue
  fi

  # -------------------------------------------------------------------------
  # A COPIA
  # -------------------------------------------------------------------------
  # `--clean --if-exists`: o destino ja tem schema, criado pela migracao do
  # proprio app no arranque. Sem limpar, o restore colide com o que existe e
  # devolve dezenas de "already exists" -- que sao tratados como aviso,
  # deixando um banco pela metade com codigo de saida zero.
  arq="$TMP_WIN/$base.dump"
  echo "  copiando..."
  if ! no_docker exec "$cont" pg_dump -U "$user" -d "$base" -Fc --clean --if-exists > "$arq" 2>"$TMP_WIN/$base.err"; then
    echo "  ERRO no pg_dump:"; tail -3 "$TMP_WIN/$base.err" | sed 's/^/      /'
    falhas=$((falhas+1)); continue
  fi

  tam=$(stat -c%s "$arq")
  # ⚠️ Piso de tamanho: um dump vazio tem ~1 KB de cabecalho e "funciona".
  if [ "$tam" -lt 5000 ]; then
    echo "  ⚠️ dump com apenas ${tam} bytes -- suspeito demais, nao restauro"
    falhas=$((falhas+1)); continue
  fi
  echo "  dump: $((tam/1024)) KB"

  # `-x --no-owner`: nao tenta recriar donos e permissoes que nao existem no
  # destino. Sem isso, o restore falha em cada `ALTER OWNER`.
  na_distro "kubectl exec -i -n $ns $pod -- pg_restore -U $user -d $base --clean --if-exists -x --no-owner < $TMP_WSL/$base.dump" \
    > "$TMP_WIN/$base.restore" 2>&1

  depois=$(contar_k3s "$ns" "$pod" "$user" "$base")
  if [ "$antes" = "$depois" ]; then
    echo "  ✅ conferido: as contagens batem, tabela a tabela"
  else
    echo "  ❌ CONTAGENS DIFERENTES -- a migracao deste banco NAO vale"
    echo "     docker: ${antes:0:200}"
    echo "     k3s   : ${depois:0:200}"
    tail -4 "$TMP_WIN/$base.restore" | sed 's/^/      /'
    falhas=$((falhas+1))
  fi
done 3<<< "$LISTA"

echo ""
echo "== bancos com problema: $falhas =="
exit "$falhas"

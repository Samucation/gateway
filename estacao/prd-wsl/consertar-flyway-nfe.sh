#!/usr/bin/env bash
# ===========================================================================
# Devolve ao historico do Flyway as migracoes que a restauracao de dados apagou.
#
#     bash consertar-flyway-nfe.sh            # confere e mostra o que faria
#     bash consertar-flyway-nfe.sh --aplicar  # insere as linhas e reinicia
#
# ---------------------------------------------------------------------------
# 🐞 O QUE ACONTECEU
# ---------------------------------------------------------------------------
# O `veltrixa-nfe-service` entrou em CrashLoop com
#
#     relation "fiscal_tabela_versao" already exists
#
# que se le como "alguem criou essa tabela na mao" e e outra coisa.
#
# A sequencia real:
#
#   1. O banco do NF-e subiu VAZIO no k3s. O Flyway aplicou V1..V19 e o
#      carregador encheu `fiscal_codigo` com 22.702 codigos oficiais.
#   2. Depois disso eu restaurei por cima o dump do banco do DOCKER, que e mais
#      ANTIGO: o historico dele para na V9, e la a V10 nunca rodou.
#   3. A restauracao SUBSTITUIU `flyway_schema_history` inteira. As tabelas das
#      migracoes novas continuaram no banco (o dump nao as tinha, entao nao
#      foram tocadas), mas o registro de que elas rodaram foi embora junto com
#      o historico velho.
#
# Resultado: um banco que nunca mais sobe. O Flyway ve dez migracoes pendentes,
# tenta criar o que ja esta la, e falha para sempre.
#
# ⚠️ A LICAO: restaurar dump sobre banco vivo pode REGREDIR o historico de
# migracao e deixar objetos novos orfaos. O estrago nao aparece na restauracao
# -- aparece na proxima partida da aplicacao, que pode ser dias depois, e a
# mensagem nao menciona nem dump nem restauracao.
#
# ---------------------------------------------------------------------------
# POR QUE MARCAR COMO APLICADA, E NAO DEIXAR RODAR
# ---------------------------------------------------------------------------
# Elas REALMENTE rodaram: os objetos existem e ha carga fiscal dentro. Apagar
# para o Flyway recriar jogaria fora dado fiscal de verdade.
#
# ⚠️ Mas "marcar como aplicada" e mentir para o Flyway se a migracao NAO tiver
# rodado. Entao cada uma so e marcada depois de PROVAR que todos os objetos que
# ela cria (tabelas e colunas) ja estao no banco. Se faltar um, o script recusa
# e diz qual -- e ai a migracao tem de rodar de verdade.
#
# O `checksum` e calculado como o Flyway calcula: CRC32 acumulado sobre os bytes
# de cada linha, sem o terminador. Se errar, a aplicacao reclama na partida com
# as duas somas na mensagem.
# ===========================================================================
set -uo pipefail

NS=veltrixa
POD=veltrixa-nfe-postgres-0
DIR=/mnt/e/Desenvolvimento/Dev/Workspace/system-api/nfe-service/src/main/resources/db/migration

roda() { kubectl exec -n "$NS" "$POD" -- psql -U nfe -d nfe_db -tAc "$1" 2>/dev/null | tr -d '\r'; }

[ -d "$DIR" ] || { echo "  ❌ nao achei $DIR"; exit 1; }

echo "== migracoes pendentes no historico =="
pendentes=""
for f in $(ls "$DIR"/V*.sql | sort -V); do
  v=$(basename "$f" | sed -E 's/^V([0-9]+)__.*/\1/')
  ja=$(roda "SELECT count(*) FROM nfe.flyway_schema_history WHERE version = '$v'")
  [ "${ja:-0}" = "0" ] && pendentes="$pendentes $v"
done
echo "  V:${pendentes:- nenhuma}"
[ -n "$pendentes" ] || { echo "  nada a fazer"; exit 0; }

echo
echo "== provando que os objetos de cada uma JA existem =="
falta=0
for v in $pendentes; do
  f=$(ls "$DIR"/V${v}__*.sql)
  faltou_nesta=""

  # Tabelas que a migracao cria.
  for t in $(grep -oiE 'CREATE TABLE (IF NOT EXISTS )?(nfe\.)?[a-z_][a-z0-9_]*' "$f" \
             | sed -E 's/.*[ .]([a-z_][a-z0-9_]*)$/\1/' | sort -u); do
    e=$(roda "SELECT count(*) FROM information_schema.tables WHERE table_schema='nfe' AND table_name='$t'")
    [ "${e:-0}" = "0" ] && faltou_nesta="$faltou_nesta tabela:$t"
  done

  # Colunas que a migracao acrescenta.
  grep -oiE 'ALTER TABLE (IF EXISTS )?(nfe\.)?[a-z_][a-z0-9_]*[[:space:]]+ADD COLUMN (IF NOT EXISTS )?[a-z_][a-z0-9_]*' "$f" \
    | while read -r linha; do
        tab=$(echo "$linha" | sed -E 's/.*ALTER TABLE (IF EXISTS )?(nfe\.)?([a-z_][a-z0-9_]*).*/\3/I')
        col=$(echo "$linha" | sed -E 's/.*ADD COLUMN (IF NOT EXISTS )?([a-z_][a-z0-9_]*)$/\2/I')
        e=$(roda "SELECT count(*) FROM information_schema.columns WHERE table_schema='nfe' AND table_name='$tab' AND column_name='$col'")
        [ "${e:-0}" = "0" ] && echo "coluna:$tab.$col" >> /tmp/faltou-$v.txt
      done
  [ -f /tmp/faltou-$v.txt ] && faltou_nesta="$faltou_nesta $(tr '\n' ' ' < /tmp/faltou-$v.txt)" && rm -f /tmp/faltou-$v.txt

  if [ -n "$faltou_nesta" ]; then
    printf '  V%-4s ❌ NAO rodou -- falta:%s\n' "$v" "$faltou_nesta"
    falta=1
  else
    printf '  V%-4s ok, tudo que ela cria ja esta no banco\n' "$v"
  fi
done

if [ "$falta" = "1" ]; then
  echo
  echo "  ❌ ha migracao que de fato NAO rodou. Nao vou marcar nada:"
  echo "     marcar uma migracao nao aplicada esconde um banco incompleto,"
  echo "     e num sistema FISCAL isso vira nota emitida errada."
  exit 1
fi

if [ "${1:-}" != "--aplicar" ]; then
  echo
  echo "  (ensaio) rode com --aplicar para registrar as $(echo $pendentes | wc -w) migracao(oes)"
  exit 0
fi

echo
echo "== registrando =="
for v in $pendentes; do
  f=$(ls "$DIR"/V${v}__*.sql)
  desc=$(basename "$f" | sed -E 's/^V[0-9]+__(.*)\.sql$/\1/' | tr '_' ' ')
  soma=$(python3 - "$f" <<'FIM'
import sys, zlib
crc = 0
with open(sys.argv[1], "rb") as arq:
    for linha in arq:
        crc = zlib.crc32(linha.rstrip(b"\r\n"), crc)
print(crc - (1 << 32) if crc >= (1 << 31) else crc)
FIM
)
  roda "INSERT INTO nfe.flyway_schema_history
          (installed_rank, version, description, type, script, checksum,
           installed_by, installed_on, execution_time, success)
        SELECT COALESCE(MAX(installed_rank), 0) + 1, '$v', '$desc', 'SQL',
               '$(basename "$f")', $soma, 'conserto-pos-migracao', now(), 0, true
        FROM nfe.flyway_schema_history" >/dev/null
  printf '  V%-4s registrada (checksum %s)\n' "$v" "$soma"
done

echo
echo "== reiniciando o servico =="
kubectl rollout restart deploy/veltrixa-nfe-service -n "$NS" >/dev/null
kubectl rollout status deploy/veltrixa-nfe-service -n "$NS" --timeout=300s | tail -1 | sed 's/^/  /'

#!/usr/bin/env bash
# ===========================================================================
# Destrava o Flyway do NF-e deixando as migracoes pendentes RODAREM de verdade.
#
#     bash destravar-flyway-nfe.sh            # confere e mostra o que faria
#     bash destravar-flyway-nfe.sh --aplicar  # apaga as 3 tabelas vazias e sobe
#
# ---------------------------------------------------------------------------
# O QUE ESTA ERRADO
# ---------------------------------------------------------------------------
# Restaurar o dump do Docker sobre o banco do k3s misturou dois estados:
#
#   * `flyway_schema_history` voltou para a V9 (a do dump);
#   * tabelas criadas por V10, V11, V17 e V18 continuaram no banco, porque o
#     dump nao as tinha e portanto nao as sobrescreveu;
#   * `tenant_fiscal_profile`, que EXISTE nos dois lados, foi SUBSTITUIDA pela
#     versao velha -- perdendo as 10 colunas que V12..V16 e V19 acrescentam.
#
# Ou seja: o banco nao esta "atrasado" nem "adiantado". Esta MISTURADO.
#
# ⚠️ Por isso marcar tudo como aplicado seria o conserto errado. O
# `conferir-migracoes-nfe.py` provou coluna a coluna que V12..V16 e V19 NAO
# rodaram; registra-las deixaria a emissao fiscal sem campos que ela usa, e o
# erro so apareceria na hora de emitir uma nota.
#
# ---------------------------------------------------------------------------
# O CONSERTO
# ---------------------------------------------------------------------------
# Deixar o Flyway aplicar V11..V19 na ordem. O unico obstaculo sao as tres
# tabelas orfas (V11, V17, V18), que fariam o script falhar com "already
# exists". As tres estao VAZIAS -- entao apagar e deixar a migracao recriar nao
# perde nada.
#
# ⚠️ A vacuidade e conferida IMEDIATAMENTE antes de apagar, e o script recusa se
# qualquer uma tiver uma linha sequer. `DROP TABLE` em banco fiscal so pode
# acontecer com prova na hora, nao com a contagem de dez minutos atras.
#
# A V10 NAO entra aqui: ela rodou de verdade e tem 22.702 codigos oficiais
# carregados. O registro dela ja foi devolvido ao historico.
# ===========================================================================
set -uo pipefail

NS=veltrixa
POD=veltrixa-nfe-postgres-0
DIR=/mnt/e/Desenvolvimento/Dev/Workspace/system-api/nfe-service/src/main/resources/db/migration

roda() { kubectl exec -n "$NS" "$POD" -- psql -U nfe -d nfe_db -tAc "$1" 2>/dev/null | tr -d '\r'; }

# 🐞 A lista de tabelas orfas sai DAS MIGRACOES PENDENTES, e nao escrita a mao.
#
# A primeira versao tinha tres nomes fixos -- os que eu tinha visto falhar. O
# Flyway parou na quarta, `tenant_contabilista`, que eu nao tinha listado; a
# seguinte pararia na quinta. Cada rodada custa um reinicio e um `rollout
# status` de cinco minutos para descobrir mais um nome.
#
# ⚠️ Lista escrita a mao esta sempre uma descoberta atrasada. Quem sabe quais
# tabelas as migracoes criam sao as migracoes.
ultima=$(roda "SELECT COALESCE(max(version::int), 0) FROM nfe.flyway_schema_history")
ORFAS=$(for f in "$DIR"/V*.sql; do
  v=$(basename "$f" | sed -E 's/^V([0-9]+)__.*/\1/')
  [ "$v" -gt "${ultima:-0}" ] || continue
  grep -oiE 'CREATE[[:space:]]+TABLE[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?(nfe\.)?[a-z_][a-z0-9_]*' "$f" \
    | sed -E 's/.*[ .]([a-z_][a-z0-9_]*)$/\1/'
done | sort -u)

echo "  ultima migracao registrada: V${ultima:-0}"
echo "  tabelas criadas pelas pendentes: $(echo $ORFAS | tr '\n' ' ')"
echo

echo "== tabelas orfas e quantas linhas tem =="
tem_dado=0
for t in $ORFAS; do
  existe=$(roda "SELECT count(*) FROM information_schema.tables WHERE table_schema='nfe' AND table_name='$t'")
  if [ "$existe" != "1" ]; then
    printf '  %-30s nao existe (nada a fazer)\n' "$t"
    continue
  fi
  n=$(roda "SELECT count(*) FROM nfe.$t")
  printf '  %-30s %s linha(s)\n' "$t" "$n"
  [ "${n:-1}" = "0" ] || tem_dado=1
done

if [ "$tem_dado" = "1" ]; then
  echo
  echo "  ❌ ha tabela COM DADO. Nao apago nada."
  echo "     Em banco fiscal, dado apagado nao volta -- e o conserto passa a"
  echo "     exigir decisao humana sobre o que fazer com essas linhas."
  exit 1
fi

echo
echo "== o que o Flyway vai aplicar depois =="
roda "SELECT '  ultima registrada: V' || max(version::int) FROM nfe.flyway_schema_history"
echo "  pendentes: V11 a V19 (o Flyway resolve a ordem)"

if [ "${1:-}" != "--aplicar" ]; then
  echo
  echo "  (ensaio) rode com --aplicar para apagar as vazias e deixar migrar"
  exit 0
fi

echo
echo "== apagando as tabelas vazias =="
for t in $ORFAS; do
  roda "DROP TABLE IF EXISTS nfe.$t CASCADE" >/dev/null
  echo "  $t apagada"
done

echo
echo "== deixando o Flyway migrar =="
kubectl rollout restart deploy/veltrixa-nfe-service -n "$NS" >/dev/null
kubectl rollout status deploy/veltrixa-nfe-service -n "$NS" --timeout=300s | tail -1 | sed 's/^/  /'

echo
echo "== conferindo o resultado =="
echo "  historico agora vai ate: V$(roda "SELECT max(version::int) FROM nfe.flyway_schema_history")"
echo "  colunas que V12..V19 acrescentam:"
for c in efd_obrigatoria clas_estab_ind regime_pis_cofins cod_rec_icms dia_vencimento_icms regime_caixa conta_contabil_receita; do
  e=$(roda "SELECT count(*) FROM information_schema.columns WHERE table_schema='nfe' AND table_name='tenant_fiscal_profile' AND column_name='$c'")
  printf '    %-26s %s\n' "$c" "$([ "$e" = "1" ] && echo ok || echo FALTA)"
done

#!/usr/bin/env bash
# ===========================================================================
# Exporta TODOS os bancos que rodam no k3s de produção.
#
# Chamado por `backup-estacao.ps1`. Roda dentro da distro WSL2 `prd`, que é
# onde o k3s vive, e escreve direto em `/mnt/g/...`.
#
# ---------------------------------------------------------------------------
# ⚠️ POR QUE ISTO DESCOBRE EM VEZ DE LISTAR
# ---------------------------------------------------------------------------
# A parte de Docker do backup tem uma tabela escrita à mão com 13 contêineres.
# Em 29/08/2026, 9 dos 13 já não existiam: a produção tinha migrado para o k3s
# meses antes, e a tabela ficou apontando para fantasmas.
#
# O backup era honesto sobre isso -- reclamava de cada um. Só que ninguém lê o
# log de uma tarefa das 02:30, e o efeito colateral passou despercebido: como
# ele sai com código 1, a ROTAÇÃO nunca rodava, e o G: chegou a 94%.
#
# O que ninguém via era pior: os 19 bancos que passaram a existir no k3s não
# estavam na tabela, então não geravam erro. Sem dump, sem falha, sem pista.
#
# Uma segunda lista à mão apodreceria do mesmo jeito. Então aqui não há lista:
# pergunta-se ao cluster quem responde como Postgres, e faz-se backup de quem
# responder. Serviço novo entra sozinho.
#
# ---------------------------------------------------------------------------
# ⚠️ NADA DE BINÁRIO ATRAVESSA CANO DE SHELL
# ---------------------------------------------------------------------------
# O dump nasce DENTRO do Pod, é conferido lá, e sai por `kubectl cp`. A
# tentação é `kubectl exec ... pg_dump > arquivo`, e é uma armadilha conhecida
# desta casa: um byte reinterpretado no caminho produz um arquivo que parece um
# dump, tem tamanho plausível, e só falha na hora de restaurar.
# ===========================================================================
set -uo pipefail

DESTINO="${1:?uso: exportar-bancos-do-k3s.sh <pasta de destino> [namespace]}"

# ⚠️ Filtro OPCIONAL, e só de namespace. Serve para conferir o script sem
# despejar dezenove dumps na produção no meio do expediente, e para restaurar a
# atenção a um projeto quando algo deu errado nele.
#
# ⚠️ Vazio significa TUDO -- e tem que significar. Se o padrão fosse um
# namespace qualquer, o backup noturno passaria a cobrir um projeto e a ignorar
# os outros, verde e silencioso.
FILTRO_NS="${2:-}"

mkdir -p "$DESTINO"

feitos=0
falhas=0
pulados=0

registrar_falha() {
    echo "FALHA|$1"
    falhas=$((falhas + 1))
}

# ---------------------------------------------------------------------------
# Quem responde como Postgres neste cluster?
#
# O filtro é por COMPORTAMENTO (`pg_isready`), e não por nome. Nome é
# convenção, e convenção quebra sem avisar; um Pod que aceita conexão de
# Postgres é um Pod que tem dados a perder, chame-se ele como se chamar.
# ---------------------------------------------------------------------------
mapfile -t CANDIDATOS < <(
    kubectl get pods -A \
        -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.containers[0].image}{"\n"}{end}' \
        2>/dev/null | grep -Ei '(postgres|postgis)' | sort
)

if [ "${#CANDIDATOS[@]}" -eq 0 ]; then
    registrar_falha "k3s: nenhum Pod de Postgres encontrado -- o cluster esta de pe?"
    echo "RESUMO|$feitos|$falhas|$pulados"
    exit 1
fi

for linha in "${CANDIDATOS[@]}"; do
    ns=$(echo "$linha" | awk '{print $1}')
    pod=$(echo "$linha" | awk '{print $2}')

    if [ -n "$FILTRO_NS" ] && [ "$ns" != "$FILTRO_NS" ]; then
        continue
    fi

    # O usuário é o que o próprio Pod declara. `postgres` é o padrão das imagens
    # oficiais quando POSTGRES_USER não foi definido.
    #
    # ⚠️ Isto vem ANTES do `pg_isready`, e a ordem custou um teste para ser
    # descoberta. O Pod roda com uid 999 sem entrada em `/etc/passwd`, então um
    # `pg_isready` sem `-U` não consegue deduzir o usuário e sai com código 3
    # ("no attempt") -- que é indistinguível de "banco fora do ar" para quem lê
    # o código de saída. Resultado do primeiro teste: o banco do cartório,
    # perfeitamente de pé, foi classificado como "pulado".
    usuario=$(kubectl exec -n "$ns" "$pod" --request-timeout=20s -- \
                sh -c 'printenv POSTGRES_USER 2>/dev/null' 2>/dev/null | tr -d '\r\n')
    [ -z "$usuario" ] && usuario="postgres"

    # ⚠️ Job de backup de outro projeto usa a MESMA imagem do Postgres e aparece
    # aqui. Ele não serve banco nenhum: o `pg_isready` o descarta sozinho, sem
    # precisar de uma regra sobre nomes.
    if ! kubectl exec -n "$ns" "$pod" --request-timeout=20s -- \
            pg_isready -q -U "$usuario" >/dev/null 2>&1; then
        pulados=$((pulados + 1))
        echo "PULADO|$ns/$pod"
        continue
    fi

    # As bases de verdade. `datallowconn` tira as template; um banco que não
    # aceita conexão também não aceita `pg_dump`.
    mapfile -t BASES < <(
        kubectl exec -n "$ns" "$pod" --request-timeout=30s -- \
            psql -U "$usuario" -At -d postgres \
            -c "SELECT datname FROM pg_database WHERE datallowconn AND datname NOT IN ('template0','template1')" \
            2>/dev/null | tr -d '\r'
    )

    if [ "${#BASES[@]}" -eq 0 ]; then
        registrar_falha "$ns/$pod: respondeu ao pg_isready mas nao listou base nenhuma"
        continue
    fi

    for base in "${BASES[@]}"; do
        [ -z "$base" ] && continue
        nome="${ns}__${pod}__${base}.dump"
        dentro="/tmp/_bkp_${base}.dump"

        if ! kubectl exec -n "$ns" "$pod" --request-timeout=600s -- \
                pg_dump -U "$usuario" -d "$base" -Fc --no-owner --no-acl -f "$dentro" >/dev/null 2>&1; then
            registrar_falha "$ns/$pod/$base: pg_dump falhou"
            kubectl exec -n "$ns" "$pod" -- rm -f "$dentro" >/dev/null 2>&1
            continue
        fi

        # ⚠️ A conferência é aqui, DENTRO do Pod, e é a que importa: um dump
        # truncado tem bytes e tem cabeçalho, e só o índice denuncia. Conferir
        # depois de copiar também valeria -- mas aí já não se sabe se o defeito
        # é do dump ou da cópia.
        if ! kubectl exec -n "$ns" "$pod" --request-timeout=120s -- \
                pg_restore --list "$dentro" >/dev/null 2>&1; then
            registrar_falha "$ns/$pod/$base: o pg_restore nao consegue ler o indice do dump"
            kubectl exec -n "$ns" "$pod" -- rm -f "$dentro" >/dev/null 2>&1
            continue
        fi

        if ! kubectl cp "$ns/$pod:$dentro" "$DESTINO/$nome" --retries=3 >/dev/null 2>&1; then
            registrar_falha "$ns/$pod/$base: nao consegui copiar o dump para fora"
            kubectl exec -n "$ns" "$pod" -- rm -f "$dentro" >/dev/null 2>&1
            continue
        fi

        kubectl exec -n "$ns" "$pod" -- rm -f "$dentro" >/dev/null 2>&1

        # ⚠️ `kubectl cp` pode voltar 0 e não deixar arquivo (caminho errado,
        # tar ausente no contêiner). Sem esta conferência, "copiado" seria uma
        # palavra e não um fato.
        if [ ! -s "$DESTINO/$nome" ]; then
            registrar_falha "$ns/$pod/$base: a copia saiu vazia"
            rm -f "$DESTINO/$nome"
            continue
        fi

        tam=$(stat -c %s "$DESTINO/$nome")
        echo "OK|$nome|$tam"
        feitos=$((feitos + 1))
    done
done

# ---------------------------------------------------------------------------
# ⚠️ ZERO DUMP É FALHA -- mesmo sem nenhum erro pelo caminho.
#
# 🐞 A primeira versão saía com 0 tendo exportado NADA: todos os Pods caíram no
# `pulados`, e "pulado" não somava falha. Ou seja, o script reproduzia
# exatamente o defeito que ele existe para corrigir -- backup verde sobre
# coisa nenhuma.
#
# Um cluster com bancos de pé sempre produz pelo menos um dump. Nenhum dump
# significa que a descoberta parou de enxergar, e isso precisa acordar alguém.
# ---------------------------------------------------------------------------
if [ "$feitos" -eq 0 ]; then
    registrar_falha "k3s: NENHUM banco exportado ($pulados Pod(s) pulados) -- a descoberta parou de enxergar?"
fi

echo "RESUMO|$feitos|$falhas|$pulados"
[ "$falhas" -eq 0 ]

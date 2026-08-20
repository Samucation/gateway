#!/usr/bin/env bash
# ===========================================================================
# Confere se os CronJobs de backup do cluster rodaram.
#
#     /usr/local/bin/conferir-backups.sh
#
# Sai 0 se todos estao em dia, 1 se algum atrasou ou sumiu. E o que o job
# `vigia-backups` do Jenkins executa.
#
# ---------------------------------------------------------------------------
# POR QUE UM SCRIPT, E NAO SHELL DENTRO DO PIPELINE
# ---------------------------------------------------------------------------
# A primeira versao vivia dentro de um bloco `"""` do Groovy, e cada `$` e cada
# `\` precisava de escape duplo. Foi la que nasceu o defeito de baixo: escrever
# certo era dificil e conferir era pior.
#
# Aqui o script roda sozinho -- da para executa-lo na VM e ver a saida de
# verdade, que e como o defeito apareceu.
#
# ---------------------------------------------------------------------------
# 🐞 A AGENDA DO CRON TEM ESPACOS, E FOI ISSO QUE QUEBROU A PRIMEIRA VERSAO
# ---------------------------------------------------------------------------
# Ela usava:
#
#     kubectl get cronjobs -o custom-columns=NS,AGENDA,ULTIMA | tr -s ' ' '|'
#
# Uma linha sai como  `veltrixa   0 3 * * *   2026-08-20T06:00:00Z`, e o `tr`
# quebra TAMBEM os espacos de dentro da agenda:
#
#     veltrixa|0|3|*|*|*|2026-08-20T06:00:00Z
#
# Entao o campo 3 -- que o script lia como "ultima execucao" -- era o campo
# HORA do cron. `date -d "3"` interpreta como 3h da manha de hoje, devolve um
# timestamp valido, e a conta de idade sai plausivel: "18h atras".
#
# ⚠️ O vigia reportava VERDE sem nunca ter olhado a data real. Um alarme que
# nao alarma e pior que nenhum, porque cria confianca.
#
# A correcao e `jsonpath` com separador proprio: os campos saem delimitados na
# origem, e espaco dentro de um valor deixa de importar.
# ===========================================================================
set -uo pipefail

K="${KUBECTL:-microk8s kubectl}"

# ⚠️ 26 horas, e nao 24. Com exatamente 24, um backup que atrasasse dez minutos
# -- no ocupado, Pod demorando a ser agendado -- apareceria como falha. Alarme
# que toca sem motivo e alarme que se aprende a ignorar.
LIMITE=$((26 * 3600))

# Quantos tem que existir. Sem esta conta, um CronJob APAGADO seria igual a um
# CronJob saudavel: a tabela ficaria toda verde, so que menor.
ESPERADOS="${ESPERADOS:-9}"

AGORA=$(date +%s)
falhou=0
total=0

printf '%-18s %-16s %-14s %-22s %s\n' NAMESPACE NOME AGENDA 'ULTIMO SUCESSO' ESTADO
printf '%s\n' '--------------------------------------------------------------------------------------------'

# `jsonpath` com `|` como separador: os campos saem delimitados na origem, e a
# agenda (que tem espacos) nao contamina os vizinhos.
while IFS='|' read -r ns nome agenda ultima; do
    [ -z "${ns:-}" ] && continue
    total=$((total + 1))

    if [ -z "${ultima:-}" ]; then
        printf '%-18s %-16s %-14s %-22s %s\n' "$ns" "$nome" "$agenda" 'NUNCA' 'FALHA'
        falhou=1
        continue
    fi

    ts=$(date -d "$ultima" +%s 2>/dev/null || echo 0)
    if [ "$ts" -eq 0 ]; then
        printf '%-18s %-16s %-14s %-22s %s\n' "$ns" "$nome" "$agenda" "$ultima" 'FALHA (data ilegivel)'
        falhou=1
        continue
    fi

    idade=$((AGORA - ts))
    horas=$((idade / 3600))

    if [ "$idade" -gt "$LIMITE" ]; then
        printf '%-18s %-16s %-14s %-22s %s\n' "$ns" "$nome" "$agenda" "${horas}h atras" 'FALHA (>26h)'
        falhou=1
    else
        printf '%-18s %-16s %-14s %-22s %s\n' "$ns" "$nome" "$agenda" "${horas}h atras" 'ok'
    fi
done < <($K get cronjobs -A -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.spec.schedule}|{.status.lastSuccessfulTime}{"\n"}{end}' 2>/dev/null)

printf '%s\n' '--------------------------------------------------------------------------------------------'
echo "$total CronJob(s) conferido(s), esperados $ESPERADOS"

if [ "$total" -lt "$ESPERADOS" ]; then
    echo "FALHA: faltam $((ESPERADOS - total)) CronJob(s). Algum foi apagado."
    falhou=1
fi

if [ "$falhou" != "0" ]; then
    echo
    echo 'HA BACKUP ATRASADO OU AUSENTE -- a coluna ESTADO diz qual.'
    exit 1
fi

echo 'todos em dia.'

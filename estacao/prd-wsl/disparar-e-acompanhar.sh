#!/usr/bin/env bash
# Reindexa o multibranch, dispara a `main` e ACOMPANHA ate terminar.
#
#     bash disparar-e-acompanhar.sh <projeto> [minutos-de-espera]
#
# ⚠️ REINDEXA ANTES de disparar, e a ordem importa.
#
# 🐞 Num multibranch o Jenkins constroi o commit que esta no INDICE dele, e nao
# o que acabou de ser empurrado. Disparar sem reindexar constroi o commit
# ANTERIOR -- e o build sai verde (ou vermelho) sobre codigo que nao e o que
# voce quer testar. O sintoma e cruel: parece que a sua mudanca nao teve efeito
# nenhum.
set -uo pipefail

J=http://127.0.0.1:8080
U=samuca
T=$(tr -d '\r\n' < /var/lib/jenkins/secrets/api-token 2>/dev/null)
[ -z "$T" ] && { echo "  ⚠️ sem token em /var/lib/jenkins/secrets/api-token"; exit 3; }

PROJ=${1:?informe o projeto}
ESPERA_MIN=${2:-25}

api() { curl -s --max-time 60 -u "$U:$T" "$@"; }

ANTES=$(api "$J/job/$PROJ/job/main/lastBuild/api/json?tree=number" \
  | sed -n 's/.*"number":\([0-9]*\).*/\1/p')
echo "  ultimo build: #${ANTES:-nenhum}"

echo "  reindexando o multibranch (para pegar o commit novo)…"
api -X POST "$J/job/$PROJ/build?delay=0" -o /dev/null
sleep 20

echo "  disparando a main…"
api -X POST "$J/job/$PROJ/job/main/build?delay=0" -o /dev/null

# Espera o numero MUDAR: disparar devolve 201 na hora, e o build so ganha
# numero quando sai da fila. Perguntar o resultado antes disso le o build
# ANTERIOR e conclui o oposto do que aconteceu.
echo -n "  esperando entrar na fila"
NOVO=nao
for _ in $(seq 1 30); do
  AGORA=$(api "$J/job/$PROJ/job/main/lastBuild/api/json?tree=number" \
    | sed -n 's/.*"number":\([0-9]*\).*/\1/p')
  if [ -n "$AGORA" ] && [ "$AGORA" != "$ANTES" ]; then NOVO=sim; break; fi
  echo -n "."
  sleep 10
done
echo

# 🐞 Aqui se anunciava "build #N começou" MESMO quando o numero nao tinha
# mudado -- ou seja, quando nenhum build novo entrou. O conferidor afirmava o
# que nao tinha verificado, e o relatorio dizia que o disparo funcionou.
#
# Acontece de verdade: se o push ja disparou o build automaticamente, o de
# agora e recusado como duplicado e o numero fica o mesmo. Acompanhar o build
# que ja estava rodando costuma ser o certo -- mas quem le precisa SABER que
# foi isso, e nao supor que o disparo criou um.
if [ "$NOVO" = "sim" ]; then
  echo "  build #${AGORA} começou (novo)"
else
  echo "  ⚠️ nenhum build NOVO entrou na fila — o numero seguiu #${AGORA:-?}."
  echo "     Provavelmente o push ja o tinha disparado. Vou acompanhar ESTE."
fi

echo -n "  acompanhando"
FIM=$((SECONDS + ESPERA_MIN * 60))
while [ $SECONDS -lt $FIM ]; do
  R=$(api "$J/job/$PROJ/job/main/lastBuild/api/json?tree=building,result")
  echo "$R" | grep -q '"building":false' && break
  echo -n "."
  sleep 30
done
echo

RESULTADO=$(api "$J/job/$PROJ/job/main/lastBuild/api/json?tree=result" \
  | sed -n 's/.*"result":"\([A-Z_]*\)".*/\1/p')

if [ -z "$RESULTADO" ]; then
  # ⚠️ "sem resultado" NAO e falha -- e "ainda esta rodando", e a diferenca
  # importa: sair 1 aqui faz quem chamou concluir que o build QUEBROU quando
  # o que houve foi a espera acabar antes dele. Ja aconteceu.
  echo "  ⏳ ainda rodando depois de ${ESPERA_MIN} min — a espera acabou, o build nao."
  echo "     Veja onde ele esta:  bash estado-dos-estagios.sh $PROJ"
  exit 2
fi

echo "  resultado: $RESULTADO"
[ "$RESULTADO" = "SUCCESS" ] || exit 1

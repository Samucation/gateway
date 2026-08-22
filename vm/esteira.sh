#!/bin/sh
# ===========================================================================
# Operar as esteiras pela API do Jenkins, de dentro da VM.
#
#   esteira.sh disparar  <projeto>
#   esteira.sh estado    <projeto>
#   esteira.sh log       <projeto> [n]
#   esteira.sh aprovar   <projeto>        # responde ao "Promover para producao?"
#   esteira.sh descartar <projeto>
#   esteira.sh esperar   <projeto>        # bloqueia ate terminar ou pedir aprovacao
#
# ---------------------------------------------------------------------------
# ⚠️ PELA PORTA 8080 DIRETO, e nao pelo tunel.
#
# O nginx que protege o Jenkins na borda apaga o cabecalho `Authorization`
# (ele o consome na propria autenticacao basica), entao a API REST responde
# 401 por fora mesmo com token valido. De dentro da VM nao ha nginx no caminho.
# ---------------------------------------------------------------------------
set -e

J=http://127.0.0.1:8080
U=claude-automacao
T=$(sudo cat /var/lib/jenkins/secrets/token-automacao)
A="-u $U:$T"

# Multibranch: o job de verdade e <projeto>/job/main.
job() { echo "$J/job/$1/job/main"; }

# ⚠️ O Jenkins exige "crumb" (anti-CSRF) em toda requisicao POST. Sem ele a
# resposta e 403 com uma pagina HTML -- que num script parece "sem permissao",
# quando na verdade e so o cabecalho faltando.
crumb() {
    curl -s --max-time 20 $A "$J/crumbIssuer/api/json" 2>/dev/null |
        sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p'
}

case "$1" in
    disparar)
        C=$(crumb)
        curl -s -o /dev/null -w "  %{http_code}\n" --max-time 30 $A \
            -H "Jenkins-Crumb: $C" -X POST "$(job "$2")/build"
        ;;

    estado)
        curl -s --max-time 20 $A "$(job "$2")/lastBuild/api/json?tree=number,building,result" 2>/dev/null |
            python3 -c 'import json,sys
d=json.load(sys.stdin)
print("  #%s  rodando=%s  resultado=%s" % (d.get("number"), d.get("building"), d.get("result")))'
        ;;

    log)
        N=${3:-60}
        curl -s --max-time 30 $A "$(job "$2")/lastBuild/consoleText" 2>/dev/null |
            sed 's/\x1b\[[0-9;]*m//g' | tail -"$N"
        ;;

    aprovar|descartar)
        # A pergunta pendente vive em `wfapi/nextPendingInputAction`. Ela traz o
        # id do passo e o nome do parametro -- os dois precisam ir na resposta.
        P=$(curl -s --max-time 20 $A "$(job "$2")/lastBuild/wfapi/nextPendingInputAction" 2>/dev/null)
        ID=$(echo "$P" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
        if [ -z "$ID" ]; then echo "  nada aguardando aprovacao"; exit 1; fi

        ACAO=Promover
        [ "$1" = "descartar" ] && ACAO=Descartar

        C=$(crumb)

        # ⚠️ `proceed` NAO E OPCIONAL, e a falta dele nao da erro: ABORTA.
        #
        # 🐞 A primeira versao mandava so o `json=` com os parametros. O
        # `InputStepExecution.doSubmit` do Jenkins decide entre prosseguir e
        # abortar olhando se existe um parametro `proceed` na requisicao --
        # sem ele, o caminho e o de rejeicao.
        #
        # O POST devolveu 200 e o build terminou com:
        #
        #     Rejected by claude-automacao
        #     Finished: ABORTED
        #
        # Ou seja: a chamada de APROVAR abortou a build, e o codigo HTTP disse
        # que deu certo. Foi assim que a build #24 do sprinklegames morreu.
        #
        # O valor de `proceed` e o rotulo do botao (`ok:` do passo `input`).
        curl -s -o /dev/null -w "  %{http_code}\n" --max-time 30 $A \
            -H "Jenkins-Crumb: $C" -X POST \
            --data-urlencode "proceed=Promover" \
            --data-urlencode "json={\"parameter\":[{\"name\":\"ACAO\",\"value\":\"$ACAO\"}]}" \
            "$(job "$2")/lastBuild/input/$ID/submit"
        ;;

    esperar)
        # ⚠️ Para quando TERMINA **ou** quando pede aprovacao. Sem a segunda
        # condicao a espera duraria os 60 minutos do `timeout` do `input`.
        i=0
        while [ $i -lt 240 ]; do
            S=$(curl -s --max-time 20 $A "$(job "$2")/lastBuild/api/json?tree=building,result" 2>/dev/null)
            echo "$S" | grep -q '"building":false' && {
                echo "$S" | sed -n 's/.*"result":"\([^"]*\)".*/  terminou: \1/p'
                exit 0
            }
            P=$(curl -s --max-time 20 $A "$(job "$2")/lastBuild/wfapi/nextPendingInputAction" 2>/dev/null)
            echo "$P" | grep -q '"id"' && { echo "  aguardando aprovacao"; exit 0; }
            i=$((i + 1))
            sleep 15
        done
        echo "  tempo esgotado"
        exit 1
        ;;

    *)
        echo "uso: esteira.sh {disparar|estado|log|aprovar|descartar|esperar} <projeto>"
        exit 2
        ;;
esac

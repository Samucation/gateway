#!/usr/bin/env bash
# ===========================================================================
# Fala com o Jenkins da distro sem depender de navegador.
#
#     bash esteira.sh disparar <projeto>
#     bash esteira.sh estado   [projeto]
#     bash esteira.sh aprovar  <projeto>
#     bash esteira.sh log      <projeto>
#
# ⚠️ Em ARQUIVO, e nao inline: `$(...)` aninhado dentro de
# `wsl.exe -- bash -c "..."` chega mastigado e vira erro de sintaxe.
# ===========================================================================
set -uo pipefail

J=http://127.0.0.1:8080
# ⚠️ O token e do `samuca`, e nao do `claude-automacao`.
#
# 🐞 Vim da VM chamando o arquivo de `token-automacao` e o usuario de
# `claude-automacao`. Aqui quem o `jenkins-token-api.groovy` cria e o token do
# `samuca`, em `secrets/api-token`. Com o par errado a resposta e 401 -- que
# parece token invalido, e e token de OUTRA conta.
U=samuca
T=$(tr -d '\r\n' < /var/lib/jenkins/secrets/api-token 2>/dev/null)
if [ -z "$T" ]; then
  echo "  ⚠️ sem token em /var/lib/jenkins/secrets/api-token"
  exit 3
fi

crumb() {
  curl -s --max-time 20 -u "$U:$T" "$J/crumbIssuer/api/json" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"]+":"+d["crumb"])'
}

acao="${1:-estado}"
proj="${2:-}"

case "$acao" in
  disparar)
    [ -n "$proj" ] || { echo "  falta o projeto"; exit 2; }
    c=$(crumb)
    # ---- A SEGUNDA VIA (02/09/2026) ----
    #
    # Pedido do dono: disparo POR AQUI vai ate producao sozinho; disparo pela
    # TELA do Jenkins continua parando no portao e esperando ele.
    #
    # ⚠️ Quem faz essa distincao e o parametro `PROMOVER_AUTO`, que SO este
    # comando envia. O padrao no Jenkinsfile e `false`, entao tela, push e
    # webhook seguem exigindo gente -- sem ninguem precisar lembrar de nada.
    #
    # 🐞 Job COM parametro exige `/buildWithParameters`; sem parametro,
    # `/build`. Trocar os dois devolve 400 -- e o 400 so recusa, nao diz o que
    # faltou. Por isso a tentativa COM parametro vem primeiro e o `/build` fica
    # de reserva: job que ainda nao conhece `PROMOVER_AUTO` (a primeira build
    # depois desta mudanca, e os projetos que nao tem o parametro) continua
    # disparando normal, so que sem a via direta.
    cod=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 -X POST \
          -u "$U:$T" -H "$c" \
          "$J/job/$proj/job/main/buildWithParameters?PROMOVER_AUTO=true")
    if [ "$cod" = "400" ] || [ "$cod" = "404" ]; then
      echo "  (este job ainda nao conhece PROMOVER_AUTO — disparo sem a via direta)"
      cod=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 -X POST \
            -u "$U:$T" -H "$c" "$J/job/$proj/job/main/build")
    fi
    echo "  $proj -> http $cod"
    ;;

  estado)
    if [ -n "$proj" ]; then
      curl -s --max-time 25 -u "$U:$T" "$J/job/$proj/job/main/lastBuild/wfapi/describe" \
        | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("  #%s  %s  (%d min)" % (d.get("id"), d.get("status"), d.get("durationMillis", 0) / 60000))
for s in d.get("stages", []):
    print("    %-42s %-12s %5ds" % (s["name"][:42], s["status"], s.get("durationMillis", 0) / 1000))
'
    else
      curl -s --max-time 40 -u "$U:$T" \
        "$J/api/json?tree=jobs%5Bname,jobs%5Bname,lastBuild%5Bnumber,building,result%5D%5D%5D" \
        | python3 -c '
import sys, json
d = json.load(sys.stdin)
for p in d.get("jobs", []):
    for b in (p.get("jobs") or []):
        if b["name"] != "main":
            continue
        lb = b.get("lastBuild") or {}
        estado = "RODANDO" if lb.get("building") else (lb.get("result") or "-")
        print("  %-24s #%-5s %s" % (p["name"], lb.get("number", "-"), estado))
'
    fi
    ;;

  aprovar)
    [ -n "$proj" ] || { echo "  falta o projeto"; exit 2; }
    id=$(curl -s --max-time 20 -u "$U:$T" \
         "$J/job/$proj/job/main/lastBuild/wfapi/nextPendingInputAction" \
         | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])' 2>/dev/null)
    [ -n "$id" ] || { echo "  $proj: nao ha nada esperando aprovacao"; exit 1; }
    c=$(crumb)
    # 🐞 `proceed` NAO e opcional, e a falta dele nao da erro: o Jenkins vai
    # pelo caminho da REJEICAO e ainda responde 200. Ja matei uma build assim.
    cod=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST \
          -u "$U:$T" -H "$c" \
          --data-urlencode 'proceed=Promover' \
          --data-urlencode 'json={"parameter":[{"name":"ACAO","value":"Promover"}]}' \
          "$J/job/$proj/job/main/lastBuild/input/$id/submit")
    echo "  $proj promovido -> http $cod"
    ;;

  log)
    [ -n "$proj" ] || { echo "  falta o projeto"; exit 2; }
    curl -s --max-time 30 -u "$U:$T" "$J/job/$proj/job/main/lastBuild/consoleText" \
      | grep -viE '^\[Pipeline\]' | tail -40
    ;;

  *)
    echo "  uso: esteira.sh disparar|estado|aprovar|log [projeto]"
    exit 2
    ;;
esac

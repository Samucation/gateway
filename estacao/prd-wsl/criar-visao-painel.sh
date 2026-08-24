#!/usr/bin/env bash
# Cria a visao `Painel` copiando a config de `Todas as esteiras`.
#
# ⚠️ SEM reiniciar o Jenkins. O script de `init.groovy.d` so roda na partida, e
# reiniciar com esteira em andamento ABORTA o que estiver rodando -- depois de
# ela ter construido, testado e analisado.
#
# 🐞 A visao `Painel` e o que o mural em `userContent/painel/` consulta
# (`view/Painel/api/json`). Sem ela a chamada devolve 404 e o painel abre VAZIO
# -- sem erro na tela e sem nada no console do navegador.
set -uo pipefail

J=http://127.0.0.1:8080
U=samuca
T=$(tr -d '\r\n' < /var/lib/jenkins/secrets/api-token 2>/dev/null)
CR=$(curl -s --max-time 20 -u "$U:$T" "$J/crumbIssuer/api/json" \
     | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"]+":"+d["crumb"])')

if curl -sf -o /dev/null --max-time 15 -u "$U:$T" "$J/view/Painel/api/json"; then
  echo "  a visao 'Painel' ja existe"
  exit 0
fi

# Pega a config da visao que ja funciona e so troca o nome.
curl -s --max-time 20 -u "$U:$T" "$J/view/Todas%20as%20esteiras/config.xml" -o /tmp/v.xml
if ! grep -q 'includeRegex' /tmp/v.xml; then
  echo "  ⚠️ nao consegui ler a config da visao existente"
  head -c 200 /tmp/v.xml; exit 1
fi
sed -i 's#<name>.*</name>#<name>Painel</name>#' /tmp/v.xml

cod=$(curl -s -o /tmp/r.txt -w '%{http_code}' --max-time 25 -X POST \
      -u "$U:$T" -H "$CR" -H 'Content-Type: application/xml' \
      --data-binary @/tmp/v.xml "$J/createView?name=Painel")
echo "  criando -> http $cod"

# ⚠️ A prova e CONSULTAR a visao, nao o codigo do POST: o Jenkins responde 200
# para varias coisas que nao criaram nada.
n=$(curl -s --max-time 20 -u "$U:$T" "$J/view/Painel/api/json?tree=jobs%5Bname%5D" \
    | grep -o '"name"' | wc -l)
echo "  visao 'Painel' com $n job(s)"

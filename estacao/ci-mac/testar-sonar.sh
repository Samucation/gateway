#!/bin/sh
# O Sonar responde do jeito que a ESTEIRA o alcanca?
#
# 🐞 Nao e' por DNS. A esteira usa `--add-host sonar.hmg:127.0.0.1` com
# `--net host`, e deixa o gateway rotear pelo cabecalho `Host`. Testar com
# `curl http://sonar.hmg/` falha no DNS e nao prova nada -- foi o erro que
# eu cometi antes.
echo "== pelo cabecalho Host, como a esteira faz =="
for p in 80 8050; do
  curl -s -o /dev/null -m 15 \
    -w "  porta $p  Host:sonar.hmg -> %{http_code}\n" \
    -H 'Host: sonar.hmg' "http://127.0.0.1:$p/api/server/version"
done

echo
echo "== corpo da resposta na 80 =="
curl -s -m 15 -H 'Host: sonar.hmg' http://127.0.0.1:80/api/server/version | head -c 200
echo

echo
echo "== e direto no Service do sonar (sem gateway) =="
IP=$(kubectl -n sonarqube get svc -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null)
PORTA=$(kubectl -n sonarqube get svc -o jsonpath='{.items[0].spec.ports[0].port}' 2>/dev/null)
echo "  service: ${IP:-?}:${PORTA:-?}"
[ -n "$IP" ] && curl -s -o /dev/null -m 15 -w "  direto -> %{http_code}\n" "http://$IP:$PORTA/api/server/version"

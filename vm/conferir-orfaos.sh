#!/usr/bin/env bash
# A conferencia que separa "migrou" de "as imagens vao aparecer".
#
# Contar linhas do banco prova so que o banco chegou. O banco guarda o PONTEIRO
# e o MinIO guarda o BYTE -- entao os dois tem que ser comparados um contra o
# outro. Um ativo sem objeto e uma imagem quebrada; um objeto sem registro e
# lixo que ninguem acha.
set -e
NS=sigma-midia
S(){ microk8s kubectl get secret sigma-midia-secrets -n $NS -o jsonpath="{.data.$1}" | base64 -d; }
PW=$(S MIDIA_DB_SENHA)

microk8s kubectl exec -n $NS sigma-midia-minio-0 -- mc alias set app http://127.0.0.1:9000 "$(S MIDIA_S3_APP_USER)" "$(S MIDIA_S3_APP_SENHA)" >/dev/null 2>&1
microk8s kubectl exec -n $NS sigma-midia-minio-0 -- mc ls --recursive app/sigma-midia 2>/dev/null | awk '{print $NF}' | sort > /tmp/no-minio.txt
microk8s kubectl exec -n $NS sigma-midia-postgres-0 -- env PGPASSWORD="$PW" psql -U midia -d sigma_midia -tAc "select chave_objeto from ativo order by 1" 2>/dev/null | tr -d '\r' | sed '/^$/d' | sort > /tmp/no-banco.txt

falta=$(comm -23 /tmp/no-banco.txt /tmp/no-minio.txt | wc -l)
sobra=$(comm -13 /tmp/no-banco.txt /tmp/no-minio.txt | wc -l)
echo "ativo SEM objeto (imagem quebrada): $falta"
echo "objeto SEM registro (lixo)........: $sobra"
[ "$falta" = "0" ] && [ "$sobra" = "0" ] && echo ">>> os dois lados batem" || echo ">>> ⚠️ DIVERGEM"
rm -f /tmp/no-minio.txt /tmp/no-banco.txt

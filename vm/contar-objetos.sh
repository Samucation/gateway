#!/usr/bin/env bash
# Conta os objetos no MinIO do cluster.
#
# 🐞 O alias do `mc` vive no arquivo de configuracao DENTRO do Pod, e some
# quando o Pod reinicia. Contar sem reconfigurar devolveu 0 com 163 objetos la
# -- e "0 objetos" leria como migracao perdida, quando era so o alias.
#
# Configurar antes de cada contagem custa nada e nao depende de estado anterior.
set -e
NS=sigma-midia
S(){ microk8s kubectl get secret sigma-midia-secrets -n $NS -o jsonpath="{.data.$1}" | base64 -d; }
microk8s kubectl exec -n $NS sigma-midia-minio-0 -- mc alias set app http://127.0.0.1:9000 "$(S MIDIA_S3_APP_USER)" "$(S MIDIA_S3_APP_SENHA)" >/dev/null 2>&1
microk8s kubectl exec -n $NS sigma-midia-minio-0 -- mc ls --recursive app/sigma-midia 2>/dev/null | wc -l

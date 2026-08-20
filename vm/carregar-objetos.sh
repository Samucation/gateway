#!/usr/bin/env bash
# Carrega os objetos de /tmp/obj para dentro do MinIO do cluster.
#
# 🐞 `kubectl cp` NAO serve aqui: ele usa `tar` DENTRO do container de destino,
# e a imagem do MinIO nao tem tar. A copia falha EM SILENCIO -- devolve sucesso
# e nao copia nada.
#
# Este Job monta o diretorio do NO e espelha pela rede, que e o caminho que o
# proprio MinIO entende.
set -e
NS=sigma-midia
cat > /tmp/carga.yaml <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: carga-objetos
  namespace: sigma-midia
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: mc
          image: minio/mc:latest
          command: ["sh","-c"]
          args:
            - |
              set -e
              mc alias set d http://sigma-midia-minio:9000 "$AU" "$AP"
              mc mirror --overwrite --quiet /origem d/sigma-midia
              echo "objetos no destino: $(mc ls --recursive d/sigma-midia | wc -l)"
          env:
            - name: AU
              valueFrom: { secretKeyRef: { name: sigma-midia-secrets, key: MIDIA_S3_APP_USER } }
            - name: AP
              valueFrom: { secretKeyRef: { name: sigma-midia-secrets, key: MIDIA_S3_APP_SENHA } }
          volumeMounts:
            - { name: origem, mountPath: /origem, readOnly: true }
      volumes:
        - name: origem
          hostPath: { path: /tmp/obj, type: Directory }
YAML
microk8s kubectl delete job carga-objetos -n $NS --ignore-not-found >/dev/null 2>&1
microk8s kubectl apply -f /tmp/carga.yaml >/dev/null
microk8s kubectl wait --for=condition=complete --timeout=600s -n $NS job/carga-objetos >/dev/null 2>&1 || true
microk8s kubectl logs -n $NS job/carga-objetos 2>/dev/null | tail -1
microk8s kubectl delete job carga-objetos -n $NS --ignore-not-found >/dev/null 2>&1
rm -rf /tmp/obj /tmp/obj.tgz /tmp/carga.yaml

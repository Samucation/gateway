# -*- coding: utf-8 -*-
"""
Gera os manifestos de Kubernetes do `opuschat` e do `cafe-mobile-erp`.

Os dois sao IRMAOS: mesma arquitetura (postgres, redis, app Dart, whisper),
nomes e portas diferentes. Um gerador aqui evita duas copias que divergiriam na
primeira correcao -- e correcao vai haver, porque a primeira versao de qualquer
manifesto esta errada em algum detalhe que so aparece rodando.

    cd <raiz do Workspace> && python gateway/ferramentas/gerar-k8s-irmaos.py
"""
import io
import os
import re

PROJETOS = [
    dict(dir='opuschat', ns='opuschat', pfx='opuschat',
         host='opuschat.hmg', img='opuschat', db='plataforma'),
    dict(dir='cafe-mobile-erp', ns='plataforma', pfx='plataforma',
         host='cafe-api.hmg', img='plataforma', db='plataforma'),
]

BANCOS = '''# ===========================================================================
# POSTGRES + REDIS do {pfx}.
#
# O Postgres e StatefulSet: banco tem identidade e disco proprio.
#
# O Redis e Deployment SEM disco, e isso e uma decisao. Aqui ele e cache e fila
# efemera. Dar disco a ele sugeriria uma durabilidade que o desenho nao promete
# -- e no dia de um incidente alguem contaria com ela.
# ===========================================================================
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {pfx}-postgres
  namespace: {ns}
spec:
  serviceName: {pfx}-postgres
  replicas: 1
  selector:
    matchLabels:
      app: {pfx}-postgres
  template:
    metadata:
      labels:
        app: {pfx}-postgres
    spec:
      securityContext:
        fsGroup: 999
        runAsUser: 999
        runAsNonRoot: true
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - name: postgres
              containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: {db}
            - name: POSTGRES_USER
              value: {db}
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {pfx}-secrets
                  key: POSTGRES_PASSWORD
            # A imagem nao aceita diretorio de dados com conteudo (o `lost+found`
            # de alguns volumes ja basta). Subdiretorio e a receita oficial.
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          # `pg_isready`, e nao porta TCP aberta.
          #
          # A porta abre ANTES de o Postgres terminar a recuperacao apos um
          # desligamento sujo. Quem conectasse nesse intervalo tomaria erro num
          # Pod que o Kubernetes ja declarou pronto.
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "{db}", "-d", "{db}"]
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 6
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "{db}"]
            initialDelaySeconds: 60
            periodSeconds: 30
            failureThreshold: 5
          resources:
            requests:
              memory: "128Mi"
              cpu: "50m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          volumeMounts:
            - name: dados
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: dados
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: microk8s-hostpath
        resources:
          requests:
            storage: 8Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {pfx}-redis
  namespace: {ns}
  labels:
    app: {pfx}-redis
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {pfx}-redis
  template:
    metadata:
      labels:
        app: {pfx}-redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          ports:
            - name: redis
              containerPort: 6379
          # `redis-cli ping` PERGUNTA ao Redis; porta aberta so diz que o
          # processo escuta. A diferenca aparece quando ele esta carregando um
          # dump grande: ele escuta, e responde LOADING a tudo.
          readinessProbe:
            exec:
              command: ["redis-cli", "ping"]
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            exec:
              command: ["redis-cli", "ping"]
            initialDelaySeconds: 30
            periodSeconds: 30
            failureThreshold: 5
          resources:
            requests:
              memory: "32Mi"
              cpu: "20m"
            limits:
              memory: "256Mi"
              cpu: "500m"
          securityContext:
            runAsNonRoot: true
            runAsUser: 999
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
'''

APP = '''# ===========================================================================
# O APP (Dart) do {pfx}.
#
# ⚠️ O `whisper` NAO esta aqui. Ele usa `faster-whisper-server:latest-cuda` e
# precisa de GPU -- e a VM nao enxerga nenhuma. Medido: ela ve so
# `VMware SVGA II Adapter`, sem nvidia-smi e sem /dev/nvidia*. Ver
# ../LEIA-ANTES.md.
#
# Como o app alcanca o whisper por URL (`WHISPER_URL`), a separacao nao exigiu
# mexer em codigo.
# ===========================================================================
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {pfx}-app
  namespace: {ns}
  labels:
    app: {pfx}-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {pfx}-app
  # `Recreate`: as migracoes do banco rodam na partida, e duas versoes migrando
  # ao mesmo tempo e problema que so aparece sob azar.
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: {pfx}-app
    spec:
      containers:
        - name: app
          image: localhost:32000/{img}:placeholder
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080

          # Tudo que NAO e segredo vem do ConfigMap de uma vez.
          #
          # `envFrom` evita trinta blocos identicos, e a lista de chaves fica num
          # arquivo de propriedades -- que se le melhor que YAML aninhado, e onde
          # dá para comentar cada valor.
          envFrom:
            - configMapRef:
                name: {pfx}-config
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: {pfx}-secrets
                  key: DATABASE_URL
            - name: REDIS_URL
              value: redis://{pfx}-redis:6379
            - name: JWT_SECRET
              valueFrom:
                secretKeyRef:
                  name: {pfx}-secrets
                  key: JWT_SECRET
            # Cifra o que o app guarda cifrado no banco.
            # ⚠️ Perde-la e perder o conteudo -- mesma familia da NFE_VAULT_KEK
            # do Veltrixa. Precisa de backup, e separado do backup do banco.
            - name: COFRE_CHAVE
              valueFrom:
                secretKeyRef:
                  name: {pfx}-secrets
                  key: COFRE_CHAVE
            - name: CENTRAL_CHAVE
              valueFrom:
                secretKeyRef:
                  name: {pfx}-secrets
                  key: CENTRAL_CHAVE
            - name: RESEND_API_KEY
              valueFrom:
                secretKeyRef:
                  name: {pfx}-secrets
                  key: RESEND_API_KEY
            - name: ATENDIMENTO_WEBHOOK_SECRET
              valueFrom:
                secretKeyRef:
                  name: {pfx}-secrets
                  key: ATENDIMENTO_WEBHOOK_SECRET
            - name: PLATFORM_ADMIN_TOTP
              valueFrom:
                secretKeyRef:
                  name: {pfx}-secrets
                  key: PLATFORM_ADMIN_TOTP

          # `/v1/messaging/health` e o caminho que a PROPRIA imagem usa no
          # HEALTHCHECK dela (ver Dockerfile). Reaproveitar em vez de inventar
          # evita o caso em que a probe testa uma rota que o app nao serve -- e
          # o Pod nunca fica pronto com a aplicacao perfeitamente sadia.
          startupProbe:
            httpGet:
              path: /v1/messaging/health
              port: http
            periodSeconds: 5
            failureThreshold: 24
          readinessProbe:
            httpGet:
              path: /v1/messaging/health
              port: http
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /v1/messaging/health
              port: http
            periodSeconds: 30
            failureThreshold: 5

          resources:
            requests:
              memory: "128Mi"
              cpu: "50m"
            limits:
              memory: "512Mi"
              cpu: "1000m"

          # 🐞 `runAsUser: 10001` e OBRIGATORIO, nao redundante.
          #
          # O Dockerfile faz `useradd --uid 10001 {pfx}` e depois `USER {pfx}` --
          # por NOME. Com `runAsNonRoot: true` o Kubernetes precisa PROVAR antes
          # de subir que o usuario nao e root, e ele nao resolve nome dentro da
          # imagem:
          #
          #   Error: container has runAsNonRoot and image has non-numeric user
          #
          # E um erro claro depois de lido e invisivel antes: no Docker a mesma
          # imagem sobe sem reclamar.
          securityContext:
            runAsNonRoot: true
            runAsUser: 10001
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            # 🐞 `/app/data` FALTAVA, e derrubava o app com
            #
            #   SqliteException(14): unable to open database file
            #
            # O ERP da cafeteria guarda um SQLite em `/app/data/cafe_server.db`,
            # e no compose isso era um volume nomeado que eu nao traduzi. Com
            # `readOnlyRootFilesystem: true` o diretorio nem podia ser criado.
            #
            # ⚠️ Aqui e um SQLite de VERDADE, com dado que precisa sobreviver ao
            # Pod -- entao e PVC, e nao emptyDir. `emptyDir` faria o banco
            # nascer vazio a cada deploy, e o sintoma seria "os dados sumiram
            # depois da atualizacao".
            - name: dados
              mountPath: /app/data
      volumes:
        - name: tmp
          emptyDir: {{}}
        - name: dados
          persistentVolumeClaim:
            claimName: {pfx}-dados
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {pfx}-dados
  namespace: {ns}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: microk8s-hostpath
  resources:
    requests:
      storage: 4Gi
'''

SVC = '''apiVersion: v1
kind: Namespace
metadata:
  name: {ns}
  labels:
    app.kubernetes.io/part-of: {ns}
---
apiVersion: v1
kind: Service
metadata:
  name: {pfx}-app
  namespace: {ns}
  labels:
    app: {pfx}-app
spec:
  type: ClusterIP
  selector:
    app: {pfx}-app
  ports:
    - name: http
      port: 8080
      targetPort: http
---
apiVersion: v1
kind: Service
metadata:
  name: {pfx}-redis
  namespace: {ns}
  labels:
    app: {pfx}-redis
spec:
  type: ClusterIP
  selector:
    app: {pfx}-redis
  ports:
    - name: redis
      port: 6379
      targetPort: redis
---
# Headless: exigido pelo StatefulSet para dar nome estavel a replica.
apiVersion: v1
kind: Service
metadata:
  name: {pfx}-postgres
  namespace: {ns}
  labels:
    app: {pfx}-postgres
spec:
  clusterIP: None
  selector:
    app: {pfx}-postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: postgres
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {pfx}
  namespace: {ns}
spec:
  ingressClassName: traefik
  rules:
    - host: {host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {pfx}-app
                port:
                  number: 8080
'''

KUST = '''# O Kustomize NAO varre diretorio sozinho: o que nao estiver aqui simplesmente
# nao existe para ele. Parece burocracia e e protecao -- um YAML esquecido numa
# pasta nunca vai para o cluster por acidente.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: {ns}

resources:
  - services.yaml
  - bancos.yaml
  - app.yaml

configMapGenerator:
  - name: {pfx}-config
    envs:
      - configmap.properties

# `includeSelectors: false` e importante: com `true` o Kustomize acrescentaria
# estes rotulos ao `selector` dos Deployments -- e `selector` e IMUTAVEL. Na
# segunda vez que alguem mexesse nos rotulos, o apply falharia com um erro que
# nao explica a causa, e o conserto seria derrubar o Deployment.
labels:
  - includeSelectors: false
    pairs:
      app.kubernetes.io/part-of: {ns}
      app.kubernetes.io/managed-by: kustomize
'''

OVER = '''# Overlay de homologacao -- so as diferencas.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: {ns}

resources:
  - ../../base

# A tag entra AQUI, e nao por `kubectl set image`.
#
# 🐞 `set image` e imperativo: o `apply` seguinte devolve o Deployment para o que
# esta declarado no overlay, os Pods novos caem em ImagePullBackOff e o cluster
# passa a discordar do repositorio sem ninguem ter errado nada.
images:
  - name: localhost:32000/{img}
    newTag: "placeholder"
'''

CONFIG = '''# Configuracao comum -- o que PODE ser lido por qualquer um.
#
# O Kustomize gera um ConfigMap disto e acrescenta um sufixo de HASH ao nome. E
# esse hash que faz a configuracao ter efeito: quando um valor muda, o nome muda,
# o Pod muda, e o Kubernetes REINICIA sozinho. Com nome fixo, alterar um valor
# nao reinicia nada -- a variavel so e lida na partida.
#
# ⚠️ Nada de senha ou chave aqui. Isso e Secret, e nao vai para o Git.

# ---- os servicos que dependem de GPU -----------------------------------
#
# ⚠️ VAZIOS DE PROPOSITO. Ver ../LEIA-ANTES.md.
#
# A VM nao enxerga GPU, entao o `whisper` nao esta no cluster. Vazias, o app
# sobe e a transcricao fica indisponivel -- comportamento honesto enquanto a
# decisao nao e tomada.
#
# Apontar para um endereco que nao responde seria pior: cada chamada esperaria o
# tempo de espera inteiro antes de falhar, e o sintoma viraria "o sistema esta
# lento", que manda investigar o lugar errado.
WHISPER_URL=
KOKORO_URL=

# ---- central-ia --------------------------------------------------------
# No compose isto era `central.interno`, resolvido pelo host-gateway ate o Kong.
# No cluster e o DNS interno, direto: um salto a menos e nada saindo da rede.
CENTRAL_URL=http://central-motor.central-ia.svc.cluster.local:3300

# ---- limites de servico ------------------------------------------------
DB_POOL=25
RATE_BURST=600
RATE_POR_SEGUNDO=200

# ---- correio -----------------------------------------------------------
EMAIL_FROM=
EMAIL_TETO_DIARIO=
EMAIL_TETO_MENSAL=

# ---- marca -------------------------------------------------------------
MARCA=
MARCA_SITE=
MARCA_SUPORTE=

# ---- IA ----------------------------------------------------------------
IA_NUVEM_LIGADA=false
IA_NOSSA_CHAVE=false

# ---- publico -----------------------------------------------------------
#
# 🐞 VAZIO, e nao `http://{host}`. O app RECUSA subir com URL publica sem TLS:
#
#   Invalid argument(s): A URL publica precisa ser https:// -- Telegram e Meta
#   recusam webhook sem TLS. Recebi "http://{host}".
#
# E uma guarda do proprio codigo, e esta certa: webhook de mensageria sem TLS
# nao funciona com nenhum dos dois provedores. Em homologacao, sem certificado
# para o `.hmg`, o honesto e deixar vazio -- o app sobe e o webhook fica
# indisponivel, em vez de subir prometendo um endereco que nao serve.
#
# Preencher no dia em que houver TLS no hostname de homologacao.
PLATFORM_PUBLIC_URL=
ALLOWED_ORIGINS=http://{host}
ADMIN_EMAILS=
'''

for p in PROJETOS:
    base = os.path.join(p['dir'], 'k8s', 'base')
    over = os.path.join(p['dir'], 'k8s', 'overlays', 'hmg')
    os.makedirs(base, exist_ok=True)
    os.makedirs(over, exist_ok=True)
    for nome, gabarito in [('bancos.yaml', BANCOS), ('app.yaml', APP),
                           ('services.yaml', SVC), ('kustomization.yaml', KUST),
                           ('configmap.properties', CONFIG)]:
        io.open(os.path.join(base, nome), 'w', encoding='utf-8', newline='\n') \
          .write(gabarito.format(**p))
    # 🐞 O overlay PRESERVA a tag ja fixada.
    #
    # A primeira versao reescrevia o arquivo inteiro, e regerar devolvia o
    # `newTag` para `placeholder` -- os Pods caiam em ImagePullBackOff logo
    # depois de uma correcao nos manifestos. O gerador apagava exatamente o unico
    # valor do overlay que NAO vem daqui.
    alvo = os.path.join(over, 'kustomization.yaml')
    novo = OVER.format(**p)
    if os.path.exists(alvo):
        atual = io.open(alvo, encoding='utf-8').read()
        m = re.search(r'newTag:\s*"([^"]+)"', atual)
        if m and m.group(1) != 'placeholder':
            novo = novo.replace('newTag: "placeholder"', 'newTag: "%s"' % m.group(1))
            print('  %s: tag preservada (%s)' % (p['dir'], m.group(1)))
    io.open(alvo, 'w', encoding='utf-8', newline='\n').write(novo)
    print('  %s/k8s: 5 arquivos na base + overlay' % p['dir'])

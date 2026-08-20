# -*- coding: utf-8 -*-
"""
Gera o CronJob de backup de cada namespace do cluster.

    python vm/gerar-backups.py

-------------------------------------------------------------------------------
POR QUE AGORA, ANTES DO CORTE
-------------------------------------------------------------------------------
Cinco dos sete namespaces nao tinham backup nenhum -- e sao justamente os que
vao RECEBER o dado de producao no corte.

Backup precisa existir ANTES do dado chegar. Criado depois, ha uma janela em
que o dado ja e insubstituivel e ainda nao tem copia; e essa janela costuma
durar mais do que se planeja, porque "backup" vira tarefa de amanha assim que a
migracao parece ter dado certo.

-------------------------------------------------------------------------------
POR QUE UM GERADOR
-------------------------------------------------------------------------------
Sao cinco arquivos quase iguais. Escritos a mao, divergem na primeira correcao
-- e correcao vai haver, porque o CronJob do sigma-midia ja precisou de duas
(HOME para o `mc`, e sair do `apk add`).

Aqui a correcao e feita uma vez e vale para todos.
"""
import io
import os

# Cada namespace, com os bancos que ele tem.
#
# `pod` e o nome do Pod do StatefulSet (sempre `-0`, porque sao replica unica);
# `chave` e a entrada do Secret que guarda a senha daquele banco.
NAMESPACES = [
    dict(ns='central-ia', hora='0 5 * * *', secret='central-ia-secrets', bancos=[
        dict(pod='central-postgres-motor-0',  user='central', db='central',        chave='POSTGRES_PASSWORD', arq='motor.dump'),
        dict(pod='central-postgres-portal-0', user='central', db='central_portal', chave='POSTGRES_PASSWORD', arq='portal.dump'),
    ]),
    dict(ns='opuschat', hora='15 5 * * *', secret='opuschat-secrets', bancos=[
        dict(pod='opuschat-postgres-0', user='plataforma', db='plataforma', chave='POSTGRES_PASSWORD', arq='app.dump'),
    ]),
    dict(ns='plataforma', hora='30 5 * * *', secret='plataforma-secrets', bancos=[
        dict(pod='plataforma-postgres-0', user='plataforma', db='plataforma', chave='POSTGRES_PASSWORD', arq='app.dump'),
    ]),
    dict(ns='sigma-financeiro', hora='45 5 * * *', secret='sigma-financeiro-secrets', bancos=[
        dict(pod='sigma-db-0',         user='sigma', db='sigma_financeiro',         chave='POSTGRES_PASSWORD', arq='producao.dump'),
        dict(pod='sigma-db-sandbox-0', user='sigma', db='sigma_financeiro_sandbox', chave='POSTGRES_PASSWORD', arq='sandbox.dump'),
    ]),
    dict(ns='sigma-payments', hora='15 6 * * *', secret='sigma-payments-secrets', bancos=[
        # DOIS bancos no mesmo servidor: o produto e o painel de operacao.
        # Levar so um daria uma restauracao que parece completa e deixa metade
        # do servico sem base.
        dict(pod='sigma-payments-postgres-0', user='sigma', db='sigma_payments', chave='POSTGRES_PASSWORD', arq='payments.dump'),
        dict(pod='sigma-payments-postgres-0', user='sigma', db='sigma_ops',      chave='POSTGRES_PASSWORD', arq='ops.dump'),
    ]),
    dict(ns='sprinklegames', hora='30 6 * * *', secret='sprinklegames-secrets', bancos=[
        dict(pod='sprinklegames-postgres-0', user='sprinkle', db='sprinklegames', chave='POSTGRES_PASSWORD', arq='app.dump'),
    ]),
    dict(ns='urupix', hora='0 6 * * *', secret='urupix-secrets', bancos=[
        dict(pod='urupix-postgres-0', user='liveflow', db='liveflow', chave='POSTGRES_PASSWORD', arq='app.dump'),
    ]),
]

GABARITO = '''# ===========================================================================
# BACKUP do namespace `{ns}`.
#
# GERADO por gateway/vm/gerar-backups.py — NAO editar a mao. Sao cinco arquivos
# quase iguais; editados um a um, divergem na primeira correcao.
#
# ---------------------------------------------------------------------------
# ⚠️ ELE RODA DE DENTRO DO CLUSTER, e isso e a escolha
# ---------------------------------------------------------------------------
# Um script no cron da maquina precisaria alcancar o banco de fora, e o banco e
# `ClusterIP` de proposito. Daria para abrir uma porta -- e ai o backup vira o
# motivo pelo qual o banco ficou exposto.
#
# ---------------------------------------------------------------------------
# O QUE ELE AINDA NAO E
# ---------------------------------------------------------------------------
# Grava num PVC da MESMA maquina. Protege contra o caso comum -- apagar tabela
# sem querer, migracao ruim -- e NAO protege contra a maquina morrer.
#
# Levar para fora e o `system-api/k8s/backup-puxar.ps1`, que roda na estacao e
# PUXA. Acrescentar este namespace na tabela dele e uma linha.
# ===========================================================================
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {ns}-backup
  namespace: {ns}
spec:
  # 🐞 `timeZone` DECLARADO. O `schedule` e avaliado pelo CONTROLADOR, cujo
  # padrao e UTC -- nao o fuso do no nem o do conteiner. Sem isto, "{hora}"
  # rodaria tres horas antes.
  #
  # E um erro que nao da erro: o backup roda, os arquivos aparecem, e so quem
  # conferir o horario percebe -- o que importa quando se escolhe a madrugada
  # justamente para pegar o banco parado.
  schedule: "{hora}"
  timeZone: America/Sao_Paulo

  # Horarios espalhados entre os namespaces: dois `pg_dump` ao mesmo tempo
  # disputam o mesmo disco, e o mais lento passa a demorar o dobro.
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  startingDeadlineSeconds: 3600

  jobTemplate:
    spec:
      backoffLimit: 2
      # Mata o Job se passar de 1 hora. Sem isto, um dump pendurado numa conexao
      # travada segura o `Forbid` e NENHUM backup roda mais -- o pior estado,
      # porque parece que esta funcionando.
      activeDeadlineSeconds: 3600
      template:
        spec:
          restartPolicy: OnFailure
          securityContext:
            fsGroup: 999
            runAsUser: 999
            runAsNonRoot: true
          containers:
            - name: dump
              image: postgres:16-alpine
              env:
                - name: TZ
                  value: America/Sao_Paulo
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: {secret}
                      key: {chave}
              command:
                - /bin/sh
                - -c
                - |
                  # `set -e` para MORRER no primeiro erro.
                  #
                  # 🐞 Sem isto, um `pg_dump` que falha deixa arquivo vazio, o
                  # script segue, e o Kubernetes marca o Job como concluido. O
                  # backup passa meses "verde" e so se descobre que esta vazio
                  # no dia da restauracao.
                  set -e
                  D=/backup/$(date +%Y%m%d-%H%M)
                  mkdir -p "$D"
                  echo "==> $D"
{comandos}
                  # PROVA de que cada arquivo presta, e nao so de que existe.
                  #
                  # `pg_restore --list` le o indice interno do dump. Truncado ou
                  # corrompido, ele falha AQUI -- e o `set -e` derruba o Job,
                  # que e o que se quer: backup ruim tem que gritar no dia em
                  # que foi feito.
                  for f in "$D"/*.dump; do
                    n=$(pg_restore --list "$f" | wc -l)
                    echo "    $(basename $f): $(du -h "$f" | cut -f1), $n objetos"
                    [ "$n" -gt 0 ] || {{ echo "VAZIO: $f"; exit 1; }}
                  done

                  # Guarda 7 dias.
                  cd /backup
                  ls -1d 20* 2>/dev/null | sort -r | tail -n +8 | while read v; do
                    echo "==> removendo antigo: $v"; rm -rf "$v"
                  done
                  echo "==> ok. ocupacao:"; du -sh /backup
              resources:
                requests:
                  memory: "64Mi"
                  cpu: "50m"
                limits:
                  memory: "256Mi"
                  cpu: "500m"
              securityContext:
                allowPrivilegeEscalation: false
                capabilities:
                  drop: ["ALL"]
              volumeMounts:
                - name: backup
                  mountPath: /backup
          volumes:
            - name: backup
              persistentVolumeClaim:
                claimName: {ns}-backup
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {ns}-backup
  namespace: {ns}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: microk8s-hostpath
  resources:
    requests:
      storage: 8Gi
'''

AQUI = os.path.dirname(os.path.abspath(__file__))
SAIDA = os.path.join(AQUI, 'backups')
os.makedirs(SAIDA, exist_ok=True)

for n in NAMESPACES:
    comandos = []
    for b in n['bancos']:
        comandos.append('                  pg_dump -h %s -U %s -d %s -Fc -f "$D/%s"'
                        % (b['pod'].rsplit('-0', 1)[0], b['user'], b['db'], b['arq']))
    # Todos os bancos de um namespace usam a mesma senha (o Secret e um so).
    chave = n['bancos'][0]['chave']
    texto = GABARITO.format(ns=n['ns'], hora=n['hora'], secret=n['secret'],
                            chave=chave, comandos='\n'.join(comandos) + '\n')
    caminho = os.path.join(SAIDA, '%s.yaml' % n['ns'])
    io.open(caminho, 'w', encoding='utf-8', newline='\n').write(texto)
    print('  %s: %d banco(s), %s' % (n['ns'], len(n['bancos']), n['hora']))

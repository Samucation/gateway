#!/usr/bin/env bash
# ===========================================================================
# Exporta os ARQUIVOS que vivem em volumes do k3s -- o que o banco só indexa.
#
# ---------------------------------------------------------------------------
# ⚠️ POR QUE ISTO EXISTE
# ---------------------------------------------------------------------------
# Backup só do banco é uma mentira útil: as linhas voltam apontando para
# arquivos que não existem mais. No cartório isso é concreto -- o currículo
# enviado numa candidatura e o documento anexado a uma solicitação são PDFs num
# volume, e o banco guarda só o caminho e o SHA-256.
#
# Restaurar só o banco devolveria um pedido de habilitação de casamento com a
# lista dos documentos recebidos e nenhum documento.
#
# ---------------------------------------------------------------------------
# ⚠️ O QUE ELE PULA, E POR QUE ISSO NÃO É POR NOME
# ---------------------------------------------------------------------------
# Volume de banco de dados NÃO entra aqui: quem cuida deles é o `pg_dump` do
# `exportar-bancos-do-k3s.sh`. Copiar o diretório de dados de um Postgres em
# funcionamento produz um retrato inconsistente -- parece backup e não restaura.
#
# A distinção é por COMPORTAMENTO: se o Pod que monta o volume responde como
# Postgres, o volume é dele e fica de fora. Distinguir por nome (`dados-*`)
# funcionaria hoje e quebraria no primeiro projeto que batizasse diferente.
# ===========================================================================
set -uo pipefail

DESTINO="${1:?uso: exportar-arquivos-do-k3s.sh <pasta de destino> [namespace]}"
FILTRO_NS="${2:-}"

mkdir -p "$DESTINO"

# ---------------------------------------------------------------------------
# ⚠️ O QUE NÃO SE COPIA, E O PORQUÊ ESCRITO AO LADO
# ---------------------------------------------------------------------------
# 🐞 A primeira execução desta rotina começou a empacotar `registro/registro-
# dados` -- o registro de imagens de contêiner. Chegou a 7,8 GB antes de ser
# interrompida. Copiar aquilo seria 7,8 GB por noite, e a rotação guarda 10
# cargas: 78 GB, num disco externo com 121 GB livres. O backup encheria o
# próprio disco e, pelo desenho do `backup-estacao.ps1`, disco cheio é falha,
# falha pula a rotação, e a partir daí nada mais é limpo.
#
# E o pior nem é o tamanho: imagem de contêiner é ARTEFATO. A esteira reconstrói
# cada uma a partir do código, que está no GitHub. Guardar 78 GB do que se
# reconstrói, num disco onde não cabe o que NÃO se reconstrói, é trocar o
# insubstituível pelo reproduzível.
#
# ⚠️ A lista é EXPLÍCITA e cada linha diz o motivo. É o oposto da tabela de
# contêineres do `backup-estacao.ps1`, que apodreceu por ser uma lista de
# INCLUSÃO escrita à mão: aqui a lista é de EXCLUSÃO, então volume novo entra
# sozinho, e esquecer de mexer aqui erra para o lado de copiar demais.
# ---------------------------------------------------------------------------
EXCLUIDOS=(
    "registro/registro-dados|imagens de conteiner: artefato, a esteira reconstroi do codigo"
    "sigma-midia/sigma-midia-backup|ja e' um backup -- copiar backup de backup"
    "veltrixa/veltrixa-backup|ja e' um backup -- copiar backup de backup"
    "sonarqube/logs-sonarqube-0|log de aplicacao, nao e' dado de cliente"
    "sonarqube/extensoes-sonarqube-0|plugins baixados, reinstalaveis"
    "sonarqube/dados-sonarqube-0|indice de busca (297 MB): reconstruido do proprio banco, ja copiado"
    "veltrixa/veltrixa-mailpit-dados|caixa de e-mail de TESTE, nao e' correspondencia real"
)

# ---------------------------------------------------------------------------
# ⚠️ O TETO, e por que ele FALHA em vez de pular.
#
# Volume grande que ninguém decidiu sobre é uma pergunta em aberto, não um
# detalhe. Se ele fosse pulado em silêncio, o dia em que um projeto novo
# guardasse 40 GB de arquivo de cliente seria o dia em que o backup deixaria de
# cobri-lo -- sem uma linha em lugar nenhum.
#
# Falhando, o backup para de rotacionar e alguém precisa vir aqui e escrever se
# aquilo é dado (aumenta o teto) ou artefato (entra na lista acima). As duas
# respostas são de uma linha; nenhuma delas é "não reparei".
# ---------------------------------------------------------------------------
LIMITE_BYTES=${LIMITE_BYTES:-2147483648}   # 2 GiB

feitos=0
falhas=0
pulados=0

registrar_falha() {
    echo "FALHA|$1"
    falhas=$((falhas + 1))
}

# Todos os volumes persistentes do cluster.
mapfile -t PVCS < <(
    kubectl get pvc -A --no-headers 2>/dev/null | awk '{print $1" "$2}' | sort
)

for entrada in "${PVCS[@]}"; do
    ns=$(echo "$entrada" | awk '{print $1}')
    pvc=$(echo "$entrada" | awk '{print $2}')

    if [ -n "$FILTRO_NS" ] && [ "$ns" != "$FILTRO_NS" ]; then
        continue
    fi

    # Está declarado como "não se copia"? Então o motivo vai para o log -- um
    # volume ausente da carga tem que ter explicação legível na própria noite,
    # e não em quem for reconstruir a decisão meses depois.
    excluido=""
    for e in "${EXCLUIDOS[@]}"; do
        if [ "${e%%|*}" = "$ns/$pvc" ]; then
            excluido="${e#*|}"
            break
        fi
    done
    if [ -n "$excluido" ]; then
        pulados=$((pulados + 1))
        echo "PULADO|$ns/$pvc ($excluido)"
        continue
    fi

    # Quem monta este volume? Sem um Pod de pé não há de onde copiar: um volume
    # só é legível de dentro de quem o montou.
    leitura=$(kubectl get pods -n "$ns" \
        -o jsonpath="{range .items[?(@.status.phase=='Running')]}{.metadata.name}{'|'}{range .spec.volumes[?(@.persistentVolumeClaim.claimName=='$pvc')]}{.name}{'|'}{end}{'\n'}{end}" \
        2>/dev/null | grep '||*.' | head -1)

    pod=$(echo "$leitura" | cut -d'|' -f1)
    volume=$(echo "$leitura" | cut -d'|' -f2)

    if [ -z "$pod" ] || [ -z "$volume" ]; then
        # ⚠️ Volume sem Pod é FALHA, e não "pulado". Ele tem dados e ninguém os
        # está copiando -- exatamente o silêncio que este script veio corrigir.
        registrar_falha "$ns/$pvc: nenhum Pod de pe monta este volume -- os dados dele ficam SEM backup"
        continue
    fi

    # É volume de banco? Então é do pg_dump, não daqui.
    usuario=$(kubectl exec -n "$ns" "$pod" --request-timeout=20s -- \
                sh -c 'printenv POSTGRES_USER 2>/dev/null' 2>/dev/null | tr -d '\r\n')
    [ -z "$usuario" ] && usuario="postgres"
    if kubectl exec -n "$ns" "$pod" --request-timeout=20s -- \
            pg_isready -q -U "$usuario" >/dev/null 2>&1; then
        pulados=$((pulados + 1))
        echo "PULADO|$ns/$pvc (volume de banco -- coberto pelo pg_dump)"
        continue
    fi

    # Onde ele está montado dentro do Pod?
    caminho=$(kubectl get pod -n "$ns" "$pod" \
        -o jsonpath="{range .spec.containers[*]}{range .volumeMounts[?(@.name=='$volume')]}{.mountPath}{'\n'}{end}{end}" \
        2>/dev/null | head -1 | tr -d '\r')

    if [ -z "$caminho" ]; then
        registrar_falha "$ns/$pvc: o Pod $pod declara o volume mas nao o monta em lugar nenhum"
        continue
    fi

    # ⚠️ MEDE ANTES DE EMPACOTAR. Descobrir o tamanho depois de gerar o pacote
    # seria tarde: o custo (disco do nó, tempo, e o `kubectl cp`) já teria sido
    # pago, e foi exatamente assim que 7,8 GB apareceram no `/tmp` de um Pod de
    # produção na primeira execução.
    tamanho=$(kubectl exec -n "$ns" "$pod" --request-timeout=120s -- \
                sh -c "du -sb '$caminho' 2>/dev/null | cut -f1" 2>/dev/null | tr -d '\r\n')

    if [ -z "$tamanho" ]; then
        registrar_falha "$ns/$pvc: nao consegui medir o tamanho de $caminho antes de empacotar"
        continue
    fi

    if [ "$tamanho" -gt "$LIMITE_BYTES" ]; then
        gb=$(awk "BEGIN{printf \"%.1f\", $tamanho/1073741824}")
        registrar_falha "$ns/$pvc: $gb GB, acima do teto -- DECIDA: e dado (suba LIMITE_BYTES) ou artefato (entre em EXCLUIDOS)?"
        continue
    fi

    nome="${ns}__${pvc}.tar.gz"
    dentro="/tmp/_bkp_arquivos.tar.gz"

    # -------------------------------------------------------------------
    # ⚠️ NEM TODO CONTÊINER TEM `tar`
    #
    # 🐞 Descoberto rodando: `sigma-midia/objetos-...-minio-0` e
    # `veltrixa/veltrixa-mailpit-dados` falharam aqui. A causa não é
    # permissão nem caminho — as imagens do MinIO e do mailpit são mínimas e
    # simplesmente não trazem `tar`. E `kubectl cp` não ajuda: ele também
    # depende de `tar` DENTRO do contêiner.
    #
    # Desistir do volume seria o pior desfecho: o do MinIO é o ACERVO DE
    # MÍDIA do sigma-midia -- arquivo de cliente, insubstituível, e que já
    # teve um episódio de restauração parcial nesta casa.
    #
    # Então quando falta `tar`, sobe-se um Pod auxiliar que monta o MESMO
    # volume e traz as ferramentas. Funciona porque o cluster é de um nó só:
    # um volume ReadWriteOnce aceita um segundo montador no mesmo nó.
    # -------------------------------------------------------------------
    usar_auxiliar="nao"
    if ! kubectl exec -n "$ns" "$pod" --request-timeout=30s -- \
            sh -c 'command -v tar >/dev/null 2>&1' >/dev/null 2>&1; then
        usar_auxiliar="sim"
    fi

    pod_tar="$pod"

    if [ "$usar_auxiliar" = "sim" ]; then
        # 🐞 `printf` e não `echo`, e o `sed` no fim não é enfeite.
        #
        # `echo` acrescenta uma quebra de linha, e `tr -c 'a-z0-9' '-'` a
        # converte em hífen junto com todo o resto: o nome saía como
        # `bkp-auxiliar-objetos-sigma-midia-minio-0-`, terminando em hífen --
        # que o Kubernetes recusa, porque nome tem de terminar em alfanumérico.
        #
        # E o erro era INVISÍVEL: o `apply` estava com a saída silenciada, então
        # o que aparecia no log era "o Pod auxiliar nao subiu", que manda quem lê
        # investigar volume, imagem e agendamento -- tudo menos a causa.
        aux="bkp-auxiliar-$(printf '%s' "$pvc" | tr -c 'a-z0-9' '-' | cut -c1-40 | sed 's/-*$//')"
        kubectl delete pod -n "$ns" "$aux" --ignore-not-found --wait=true >/dev/null 2>&1

        # ⚠️ `readOnly: true`. O auxiliar existe para LER. Sem isto, um erro de
        # digitação num `tar` dentro dele poderia escrever no acervo que ele
        # veio salvar.
        # ⚠️ A saída do `apply` é GUARDADA, não descartada. Foi justamente
        # descartá-la que escondeu o nome inválido acima.
        erro_apply=$(cat <<FIM | kubectl apply -f - 2>&1 >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $aux
  namespace: $ns
  labels:
    app.kubernetes.io/managed-by: backup-estacao
spec:
  restartPolicy: Never
  containers:
    - name: tar
      image: alpine:3.20
      command: ["sleep", "1800"]
      volumeMounts:
        - name: alvo
          mountPath: $caminho
          readOnly: true
  volumes:
    - name: alvo
      persistentVolumeClaim:
        claimName: $pvc
FIM
)

        if [ -n "$erro_apply" ]; then
            registrar_falha "$ns/$pvc: o conteiner nao tem tar e o Pod auxiliar foi recusado -- $(echo "$erro_apply" | head -1)"
            continue
        fi

        if ! kubectl wait -n "$ns" --for=condition=Ready "pod/$aux" --timeout=180s >/dev/null 2>&1; then
            motivo=$(kubectl get pod -n "$ns" "$aux" \
                        -o jsonpath='{.status.phase}{" "}{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
            registrar_falha "$ns/$pvc: o conteiner nao tem tar e o Pod auxiliar nao ficou pronto (${motivo:-sem estado})"
            kubectl delete pod -n "$ns" "$aux" --ignore-not-found >/dev/null 2>&1
            continue
        fi
        pod_tar="$aux"
    fi

    # O tar nasce DENTRO do Pod e sai por `kubectl cp`, pelo mesmo motivo dos
    # dumps: binário que atravessa cano de shell volta corrompido sem avisar.
    if ! kubectl exec -n "$ns" "$pod_tar" --request-timeout=1800s -- \
            tar -czf "$dentro" -C "$caminho" . >/dev/null 2>&1; then
        registrar_falha "$ns/$pvc: nao consegui empacotar $caminho"
        kubectl exec -n "$ns" "$pod_tar" -- rm -f "$dentro" >/dev/null 2>&1
        [ "$usar_auxiliar" = "sim" ] && kubectl delete pod -n "$ns" "$pod_tar" --ignore-not-found >/dev/null 2>&1
        continue
    fi

    # Guarda o auxiliar num lugar só, para o encerramento não depender de
    # lembrar dele em cada saída do laço.
    limpar_auxiliar() {
        [ "$usar_auxiliar" = "sim" ] && \
            kubectl delete pod -n "$ns" "$pod_tar" --ignore-not-found >/dev/null 2>&1
    }

    # Confere o pacote ANTES de copiar. `tar -t` lê o índice inteiro; um pacote
    # truncado tem bytes e falha aqui.
    if ! kubectl exec -n "$ns" "$pod_tar" --request-timeout=600s -- \
            tar -tzf "$dentro" >/dev/null 2>&1; then
        registrar_falha "$ns/$pvc: o pacote gerado nao e legivel"
        kubectl exec -n "$ns" "$pod_tar" -- rm -f "$dentro" >/dev/null 2>&1
        limpar_auxiliar
        continue
    fi

    if ! kubectl cp "$ns/$pod_tar:$dentro" "$DESTINO/$nome" --retries=3 >/dev/null 2>&1; then
        registrar_falha "$ns/$pvc: nao consegui copiar o pacote para fora"
        kubectl exec -n "$ns" "$pod_tar" -- rm -f "$dentro" >/dev/null 2>&1
        limpar_auxiliar
        continue
    fi

    kubectl exec -n "$ns" "$pod_tar" -- rm -f "$dentro" >/dev/null 2>&1

    if [ ! -s "$DESTINO/$nome" ]; then
        registrar_falha "$ns/$pvc: a copia saiu vazia"
        rm -f "$DESTINO/$nome"
        limpar_auxiliar
        continue
    fi

    tam=$(stat -c %s "$DESTINO/$nome")

    # ⚠️ A CONTAGEM vai para o manifesto de propósito. Um pacote válido de uma
    # pasta vazia é indistinguível, pelo tamanho, de um pacote válido de uma
    # pasta que ESVAZIOU. `cartorio-arquivos` hoje tem 0 arquivos e 86 bytes --
    # legítimo, porque ninguém anexou documento ainda. No dia em que tiver 500
    # currículos e voltar a 0, a única coisa que vai gritar é este número
    # comparado com o da carga anterior.
    quantos=$(kubectl exec -n "$ns" "$pod_tar" --request-timeout=120s -- \
                sh -c "find '$caminho' -type f 2>/dev/null | wc -l" 2>/dev/null | tr -d '\r\n')
    [ -z "$quantos" ] && quantos="?"

    limpar_auxiliar

    echo "OK|$nome|$tam|${quantos} arquivo(s) em $caminho"
    feitos=$((feitos + 1))
done

# ⚠️ Rede de segurança: se o script morreu no meio de um volume, o Pod auxiliar
# daquele volume ficaria de pé segurando um ReadWriteOnce -- e o dono legítimo
# não conseguiria reiniciar. Uma varredura no fim custa nada e evita um sintoma
# que ninguém ligaria ao backup.
for orfao in $(kubectl get pods -A -l app.kubernetes.io/managed-by=backup-estacao \
                    --no-headers 2>/dev/null | awk '{print $1"/"$2}'); do
    kubectl delete pod -n "${orfao%%/*}" "${orfao##*/}" --ignore-not-found >/dev/null 2>&1
    echo "PULADO|auxiliar orfao removido: $orfao"
done

echo "RESUMO|$feitos|$falhas|$pulados"
[ "$falhas" -eq 0 ]

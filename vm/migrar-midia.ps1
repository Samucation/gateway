# ===========================================================================
# MIGRA o sigma-midia — banco E objetos.
#
#     .\vm\migrar-midia.ps1              # migra
#     .\vm\migrar-midia.ps1 -Conferir    # só compara os dois lados
#
# ---------------------------------------------------------------------------
# POR QUE ELE É SEPARADO DO `migrar-dados.ps1`
# ---------------------------------------------------------------------------
# Todos os outros projetos guardam tudo no Postgres. Este guarda em DOIS
# lugares, e a relação entre eles é de ponteiro:
#
#   banco  -> quem enviou, quando, que tamanho, e a CHAVE do objeto
#   MinIO  -> o byte
#
# ⚠️ Migrar só o banco daria uma restauração de aparência PERFEITA — todas as
# linhas no lugar — com TODAS as imagens quebradas. É o pior tipo de falha: a
# que parece ter dado certo. E as imagens são as thumbnails do Urupix e as
# fotos do catálogo do Veltrixa; quem sentiria é o usuário final deles.
#
# Por isso a conferência final compara os DOIS lados um contra o outro: todo
# ativo do banco tem que ter objeto, e todo objeto tem que ter registro.
#
# ---------------------------------------------------------------------------
# ⚠️ AS CHAVES DOS OBJETOS NÃO PODEM MUDAR
# ---------------------------------------------------------------------------
# As URLs que o Urupix e o Veltrixa já guardaram apontam para caminhos DENTRO do
# bucket, e são assinadas. Preservar o nome do bucket e a chave de cada objeto
# não é organização: é o que faz as imagens continuarem aparecendo.
# ===========================================================================
param(
    # ⚠️ Vazio de proposito: a VM esta em DHCP e ja trocou de IP tres vezes num
    # dia. IP fixo aqui falhava com "Connection timed out" -- erro que parece
    # maquina fora do ar, e nao endereco trocado. Vazio, o `achar-vm.ps1`
    # descobre e CONFERE O HOSTNAME antes de devolver.
    [string]$Vm      = "",
    [string]$Usuario = "usuario",
    [string]$Chave   = "$env:USERPROFILE\.ssh\id_hmg_veltrixa",
    [switch]$Conferir
)

# `Continue`, e não `Stop`: no PowerShell 5.1 a saída de erro de programa
# externo vira ErrorRecord, e um aviso rotineiro do `psql` mataria o script no
# meio. As falhas que importam são conferidas explicitamente.
$ErrorActionPreference = 'Continue'

if (-not $Vm) {
    $Vm = & (Join-Path $PSScriptRoot 'achar-vm.ps1')
    if (-not $Vm) { throw "nao achei a serverhomol na rede" }
    Write-Host "==> serverhomol em $Vm" -ForegroundColor Cyan
}

$ProgressPreference    = 'SilentlyContinue'

function Log($m) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

$ssh = @('-i', $Chave, '-o', 'BatchMode=yes', "$Usuario@$Vm")
$carimbo = Get-Date -Format 'yyyyMMdd-HHmmss'

$PW = (& ssh @ssh "sudo microk8s kubectl get secret sigma-midia-secrets -n sigma-midia -o jsonpath='{.data.MIDIA_DB_SENHA}' | base64 -d") -join ''
if (-not $PW) { throw "nao consegui ler a senha do banco no cluster" }

$SQL = "select count(*) from ativo"

# ---------------------------------------------------------------------------
# Quanto existe de cada lado, ANTES.
# ---------------------------------------------------------------------------
$ativosOrigem  = ($SQL | docker exec -i sigma-midia-postgres psql -U midia -d sigma_midia -tA) -join ''
$ativosOrigem  = $ativosOrigem.Trim()
$objetosOrigem = (docker exec sigma-midia-minio sh -c 'mc alias set l http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; mc ls --recursive l/sigma-midia 2>/dev/null | wc -l') -join ''
$objetosOrigem = $objetosOrigem.Trim()
Log "origem:  $ativosOrigem ativos no banco, $objetosOrigem objetos no MinIO"

if ($Conferir) {
    $a = ($SQL | & ssh @ssh "sudo microk8s kubectl exec -i -n sigma-midia sigma-midia-postgres-0 -- env PGPASSWORD='$PW' psql -U midia -d sigma_midia -tA 2>/dev/null") -join ''
    $o = (& ssh @ssh "sudo bash /var/lib/jenkins/gateway/vm/contar-objetos.sh") -join ''
    Log "destino: $($a.Trim()) ativos, $($o.Trim()) objetos"
    if ($a.Trim() -eq $ativosOrigem -and $o.Trim() -eq $objetosOrigem) { Log "CONFEREM"; exit 0 }
    Log "⚠️ DIVERGEM"; exit 1
}

# ---------------------------------------------------------------------------
# 1. O banco.
# ---------------------------------------------------------------------------
$dump = "$env:TEMP\midia-$carimbo.dump"
docker exec sigma-midia-postgres pg_dump -U midia -d sigma_midia -Fc -f /tmp/m.dump 2>$null
docker cp sigma-midia-postgres:/tmp/m.dump $dump | Out-Null
docker exec sigma-midia-postgres rm -f /tmp/m.dump 2>$null | Out-Null

# Assinatura "PG": tamanho parecido não prova que o arquivo é o que se pensa.
$cab = [System.IO.File]::ReadAllBytes($dump)[0..1]
if ([char]$cab[0] + [char]$cab[1] -ne 'PG') { throw "dump sem assinatura PG" }
Log ("banco:   {0} KB, assinatura PG ok" -f [math]::Round((Get-Item $dump).Length/1KB,1))

& scp -i $Chave -o BatchMode=yes -q $dump "${Usuario}@${Vm}:/tmp/m.dump" | Out-Null

# O app para de escrever enquanto o banco é recriado. Sem isto ele reconectaria
# no meio da restauração e gravaria em cima do que está entrando.
& ssh @ssh "sudo microk8s kubectl scale deploy/sigma-midia -n sigma-midia --replicas=0 >/dev/null 2>&1"
Start-Sleep -Seconds 8

$recriar = @(
  "sudo microk8s kubectl exec -n sigma-midia sigma-midia-postgres-0 -- env PGPASSWORD='$PW' psql -U midia -d postgres -c \""select pg_terminate_backend(pid) from pg_stat_activity where datname='sigma_midia' and pid<>pg_backend_pid()\"" >/dev/null 2>&1",
  "sudo microk8s kubectl exec -n sigma-midia sigma-midia-postgres-0 -- env PGPASSWORD='$PW' psql -U midia -d postgres -c 'drop database if exists sigma_midia' >/dev/null 2>&1",
  "sudo microk8s kubectl exec -n sigma-midia sigma-midia-postgres-0 -- env PGPASSWORD='$PW' psql -U midia -d postgres -c 'create database sigma_midia' >/dev/null 2>&1"
) -join '; '
& ssh @ssh $recriar | Out-Null

& ssh @ssh "sudo microk8s kubectl cp /tmp/m.dump sigma-midia/sigma-midia-postgres-0:/tmp/m.dump >/dev/null 2>&1"
& ssh @ssh "sudo microk8s kubectl exec -n sigma-midia sigma-midia-postgres-0 -- env PGPASSWORD='$PW' pg_restore -U midia -d sigma_midia --no-owner --no-privileges /tmp/m.dump 2>&1 | tail -2" | ForEach-Object { if ($_) { Log "  $_" } }
Remove-Item $dump -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 2. Os objetos.
#
# 🐞 `kubectl cp` NÃO serve para o MinIO: ele usa `tar` DENTRO do contêiner de
# destino, e a imagem do MinIO não tem tar. A cópia falha EM SILÊNCIO — devolve
# sucesso e não copia nada.
#
# O caminho é: espelhar para o disco daqui, levar empacotado, e do lado de lá
# um Job que monta o diretório do nó e espelha pela rede — que é o caminho que
# o próprio MinIO entende.
# ---------------------------------------------------------------------------
$obj = "$env:TEMP\midia-obj-$carimbo"
if (Test-Path $obj) { Remove-Item $obj -Recurse -Force }
New-Item -ItemType Directory -Force -Path $obj | Out-Null

$ru = (docker exec sigma-midia-minio printenv MINIO_ROOT_USER) -join ''
$rp = (docker exec sigma-midia-minio printenv MINIO_ROOT_PASSWORD) -join ''
docker run --rm --network sigma-midia_default -v "${obj}:/out" --entrypoint sh minio/mc:latest -c `
  "mc alias set o http://sigma-midia-minio:9000 '$ru' '$rp' >/dev/null && mc mirror --quiet o/sigma-midia /out" | Out-Null

$n = (Get-ChildItem $obj -Recurse -File).Count
Log "objetos: $n arquivos espelhados para o disco"
if ($n -ne [int]$objetosOrigem) { throw "espelhei $n de $objetosOrigem objetos" }

$tgz = "$env:TEMP\midia-obj-$carimbo.tgz"
# ⚠️ `--force-local`: sem isto o tar le `E:/caminho` como HOST REMOTO
# (a sintaxe `maquina:/caminho` de fita), tenta abrir uma conexao e morre
# com "Cannot write: Broken pipe" — mensagem que nao tem nada a ver com a
# causa. O pacote nao e criado e o `scp` seguinte falha com "No such file".
#
# 🐞 Em 21/08/2026 isto deixou o destino PIOR que antes: as 10 linhas novas
# do banco foram restauradas e os objetos nao, entao o destino passou de
# 163/163 (consistente, so atrasado) para 173/163 — dez imagens quebradas.
# ⚠️ Migracao que falha no meio nao e neutra: ela pode deixar o destino em
# estado que nao existia em lugar nenhum.
tar --force-local -czf $tgz -C $obj .
& scp -i $Chave -o BatchMode=yes -q $tgz "${Usuario}@${Vm}:/tmp/obj.tgz" | Out-Null
Remove-Item $obj -Recurse -Force; Remove-Item $tgz -Force

& ssh @ssh "sudo rm -rf /tmp/obj && sudo mkdir -p /tmp/obj && sudo tar xzf /tmp/obj.tgz -C /tmp/obj" | Out-Null
& ssh @ssh "sudo bash /var/lib/jenkins/gateway/vm/carregar-objetos.sh" | ForEach-Object { if ($_) { Log "  $_" } }

& ssh @ssh "sudo microk8s kubectl scale deploy/sigma-midia -n sigma-midia --replicas=1 >/dev/null 2>&1"

# ---------------------------------------------------------------------------
# 3. A CONFERÊNCIA QUE IMPORTA — os dois lados, um contra o outro.
#
# Contar linhas do banco provaria só que o banco chegou. O que separa "migrou"
# de "as imagens vão aparecer" é todo ativo ter o seu objeto.
# ---------------------------------------------------------------------------
Start-Sleep -Seconds 10
$a = ($SQL | & ssh @ssh "sudo microk8s kubectl exec -i -n sigma-midia sigma-midia-postgres-0 -- env PGPASSWORD='$PW' psql -U midia -d sigma_midia -tA 2>/dev/null") -join ''
$o = (& ssh @ssh "sudo bash /var/lib/jenkins/gateway/vm/contar-objetos.sh") -join ''
$a = $a.Trim(); $o = $o.Trim()

$orfaos = (& ssh @ssh "sudo bash /var/lib/jenkins/gateway/vm/conferir-orfaos.sh") -join "`n"

Write-Output ""
Log "destino: $a ativos, $o objetos   (origem: $ativosOrigem / $objetosOrigem)"
$orfaos -split "`n" | ForEach-Object { if ($_) { Log "  $_" } }

if ($a -ne $ativosOrigem -or $o -ne $objetosOrigem) {
    Log "⚠️ DIVERGE da origem. NAO siga com o corte."
    exit 1
}
Log "confere. Origem intacta."

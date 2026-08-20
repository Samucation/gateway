# ===========================================================================
# BACKUP DESTA ESTAÇÃO — os bancos que rodam em Docker aqui.
#
#     powershell -ExecutionPolicy Bypass -File gateway\estacao\backup-estacao.ps1
#
# ---------------------------------------------------------------------------
# POR QUE ELE EXISTE, E POR QUE É O MAIS IMPORTANTE DOS DOIS
# ---------------------------------------------------------------------------
# O outro script (`system-api/k8s/backup-puxar.ps1`) PUXA os backups da VM de
# homologação. Ele protege dados de teste: os dumps de lá têm 0,1 MB, porque
# são esquema vazio.
#
# Os dados REAIS estão aqui. Medido em 20/08/2026:
#
#     liveflow          31 MB   <- doações PIX de terceiro
#     sigma_financeiro  22 MB
#     plataforma        15 MB
#     veltrixa_db       13 MB
#     mídia (MinIO)     25 MB
#
# E até hoje eles não tinham cópia em lugar nenhum. Enquanto a migração para o
# servidor não terminar, o risco desta montagem não é desligar o Docker: é o
# SSD desta máquina.
#
# ---------------------------------------------------------------------------
# ⚠️ AQUI OS DUMPS SÃO CIFRADOS. LÁ NÃO SÃO, E A DIFERENÇA É PROPOSITAL
# ---------------------------------------------------------------------------
# O `backup-puxar.ps1` deixa os dumps em claro porque são de homologação, e diz
# na própria cabeça dele: "no dia em que houver dado real aqui, isto tem que
# mudar". Este é esse dia, e este é esse arquivo.
#
# Tudo sai cifrado com `age`, para a MESMA chave do backup de homologação:
#
#     C:\Users\samue\.chaves\hmg-backup-age.key
#     D:\chaves\hmg-backup-age.key            (segunda cópia, outro disco)
#
# Mesma chave, e não uma segunda: uma segunda chave seria uma segunda coisa
# para perder, e o modo de falha aqui não é alguém decifrar o backup — é não
# haver mais chave nenhuma no dia de restaurar.
#
# ⚠️ Só a chave PÚBLICA é usada para cifrar, então este script nunca lê a
# privada. Ele funciona com a chave guardada num cofre, offline.
#
# ---------------------------------------------------------------------------
# ONDE ELE ESCREVE, E POR QUÊ
# ---------------------------------------------------------------------------
# `G:` é um WD Elements USB — disco FÍSICO separado do `E:` (Kingston, onde
# mora o código) e do `C:`/`F:` (Samsung). Backup no mesmo disco do original
# não é backup: é uma segunda cópia do mesmo ponto de falha.
#
# ⚠️ Sendo USB, ele pode estar desconectado. O script FALHA ALTO nesse caso, em
# vez de criar a pasta e seguir — ver a próxima seção.
#
# ---------------------------------------------------------------------------
# 🐞 A REGRA QUE NASCEU DE UM DEFEITO DO OUTRO SCRIPT
# ---------------------------------------------------------------------------
# Em 20/08/2026 achei em `G:\Backups\hmg\veltrixa` a pasta `20260820-1300` com
# ZERO arquivos: a puxada rodou quando a VM caiu, criou a pasta datada e não
# colocou nada nela.
#
# Numa listagem aquilo tem cara de backup. Com rotação por dias, uma sequência
# dessas substituiria as cópias boas por pastas vazias — e o dia de descobrir
# seria o dia da restauração.
#
# Então aqui: NENHUMA carga é dada por boa sem passar por `Confirmar-Carga`, e
# a rotação **só apaga carga antiga se houver uma carga nova VÁLIDA**. Um
# backup que falhou tem que gritar, não empurrar o bom para fora.
# ===========================================================================
param(
    [string]$Destino    = "G:\Backups\estacao",
    [int]$ManterCargas  = 10,
    [string]$Apenas     = "",
    [switch]$SemMidia
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# A chave PÚBLICA. Cifrar não exige a privada — ver a nota na cabeça.
$RECIPIENTE = 'age122t884r4lq8jpexlkqxeumz52dny6rs0upxz22kqfxc0qh7qyvuqy2a5yk'

# ---------------------------------------------------------------------------
# A TABELA. Levantada do Docker em 20/08/2026, não escrita de cabeça.
#
# ⚠️ Estão aqui as bases de teste (`_e2e`, `_teste`, `_sandbox`) DE PROPÓSITO.
# Excluí-las economizaria uns poucos MB num disco com 292 GB livres, e em troca
# criaria uma decisão que pode estar errada — a `sigma_financeiro_sandbox`, por
# exemplo, guarda credencial de sandbox configurada à mão. Regra simples: leva
# tudo, não esquece nada.
# ---------------------------------------------------------------------------
$BANCOS = @(
    @{ Cont='liveflow-db';               User='liveflow';   Bases=@('liveflow','liveflow_e2e') }
    @{ Cont='sigma-db';                  User='sigma';      Bases=@('sigma_financeiro','sigma_financeiro_e2e') }
    @{ Cont='sigma-db-sandbox';          User='sigma';      Bases=@('sigma_financeiro_sandbox') }
    @{ Cont='sigma-payments-postgres-1'; User='sigma';      Bases=@('sigma_payments','sigma_ops') }
    @{ Cont='veltrixa-postgres';         User='veltrixa';   Bases=@('veltrixa_db') }
    @{ Cont='veltrixa-nfe-postgres';     User='nfe';        Bases=@('nfe_db') }
    @{ Cont='veltrixa-keycloak-postgres';User='keycloak';   Bases=@('keycloak_db') }
    @{ Cont='sigma-midia-postgres';      User='midia';      Bases=@('sigma_midia') }
    @{ Cont='plataforma-db';             User='plataforma'; Bases=@('plataforma') }
    @{ Cont='opuschat-db';               User='plataforma'; Bases=@('plataforma') }
    @{ Cont='central-db-motor';          User='central';    Bases=@('central') }
    @{ Cont='central-db-portal';         User='central';    Bases=@('central_portal') }
    @{ Cont='sprinklegames-postgres';    User='sprinkle';   Bases=@('sprinklegames','sprinklegames_teste') }
)

# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
function Diga($m)   { Write-Host "  $m" }
function Passo($m)  { Write-Host "`n== $m" -ForegroundColor Cyan }
function Ok($m)     { Write-Host "  ok    $m" -ForegroundColor Green }
function Falha($m)  { Write-Host "  FALHA $m" -ForegroundColor Red }

$erros = New-Object Collections.Generic.List[string]

# `docker exec` escreve o dump no stdout. ⚠️ Em PowerShell 5.1 NÃO se pode
# passar binário pelo pipeline: ele decodifica como texto e o arquivo sai
# corrompido, sem erro nenhum. Por isso o redirecionamento é do PROCESSO, feito
# pelo cmd, e não pelo PowerShell.
function Exportar-Banco($cont, $user, $base, $saida) {
    $cmd = "docker exec $cont pg_dump -U $user -d $base -Fc --no-owner --no-acl"
    & cmd.exe /c "$cmd > `"$saida`" 2>`"$saida.err`""
    return $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# ⚠️ A GUARDA. Nenhuma carga é dada por boa sem passar por aqui.
#
# Confere três coisas, e a terceira é a que importa:
#   1. o arquivo existe e não é vazio;
#   2. começa com a assinatura `PGDMP` (é mesmo um dump, não uma mensagem de
#      erro que o shell despejou no arquivo);
#   3. o `pg_restore --list` consegue LER o índice dele. Um dump truncado passa
#      nos dois primeiros e falha aqui — que é exatamente o caso que arruína
#      uma restauração.
# ---------------------------------------------------------------------------
function Confirmar-Dump($cont, $arquivo) {
    if (-not (Test-Path $arquivo))              { return "não foi criado" }
    $tam = (Get-Item $arquivo).Length
    if ($tam -lt 100)                           { return "vazio ou truncado ($tam bytes)" }

    $fs = [IO.File]::OpenRead($arquivo)
    try {
        $cab = New-Object byte[] 5
        $lidos = $fs.Read($cab, 0, 5)
        $texto = [Text.Encoding]::ASCII.GetString($cab, 0, $lidos)
    } finally { $fs.Dispose() }
    if ($texto -ne 'PGDMP')                     { return "não é um dump do Postgres (começa com '$texto')" }

    # O índice tem que ser legível. É a diferença entre "tem bytes" e "restaura".
    $nome = Split-Path $arquivo -Leaf
    & cmd.exe /c "docker cp `"$arquivo`" ${cont}:/tmp/_conf.dump >nul 2>&1"
    & cmd.exe /c "docker exec $cont pg_restore --list /tmp/_conf.dump >nul 2>&1"
    $rc = $LASTEXITCODE
    & cmd.exe /c "docker exec $cont rm -f /tmp/_conf.dump >nul 2>&1"
    if ($rc -ne 0)                              { return "o pg_restore não consegue ler o índice" }

    return $null   # sem erro
}

function Cifrar($origem, $destino) {
    & age -r $RECIPIENTE -o $destino $origem
    if ($LASTEXITCODE -ne 0) { throw "age falhou ao cifrar $origem" }
    Remove-Item $origem -Force
}

# ---------------------------------------------------------------------------
# ⚠️ O destino tem que EXISTIR como disco. Se o `G:` estiver desconectado,
# `New-Item` criaria alegremente uma pasta `G:\...` — não, o Windows recusa
# letra inexistente, mas se alguém apontar `-Destino` para o disco local o
# script gravaria backup no mesmo disco do original, que não é backup.
# ---------------------------------------------------------------------------
$letra = (Split-Path $Destino -Qualifier)
if (-not (Test-Path $letra)) {
    Falha "o disco $letra não está montado. O WD Elements (G:) está conectado?"
    exit 1
}

$carimbo = Get-Date -Format 'yyyyMMdd-HHmm'
$pasta   = Join-Path $Destino $carimbo
New-Item -ItemType Directory -Path $pasta -Force | Out-Null

Write-Host "`n=== BACKUP DA ESTAÇÃO — $carimbo ===" -ForegroundColor White
Diga "destino: $pasta"
Diga "cifrado para: $RECIPIENTE"

# ---------------------------------------------------------------------------
# 1. OS BANCOS
# ---------------------------------------------------------------------------
Passo "Bancos"
$feitos = 0
foreach ($b in $BANCOS) {
    if ($Apenas -and $b.Cont -notlike "*$Apenas*") { continue }

    # 🐞 O filtro é montado FORA da string. Escrito como
    # `"name=^/$($b.Cont)$"`, o `$"` final faz o PowerShell abrir uma
    # subexpressão e engolir a aspa de fechamento — e o erro que ele reporta é
    # uma chave desbalanceada 5 linhas ADIANTE, que não tem relação nenhuma com
    # a causa.
    $filtro = 'name=^/' + $b.Cont + '$'
    $vivo = (& docker ps --filter $filtro --format '{{.Names}}' 2>$null)
    if (-not $vivo) {
        Falha "$($b.Cont) não está em pé — PULADO"
        $erros.Add("$($b.Cont): contêiner fora do ar")
        continue
    }

    foreach ($base in $b.Bases) {
        $cru = Join-Path $pasta "$($b.Cont)__$base.dump"
        $rc  = Exportar-Banco $b.Cont $b.User $base $cru

        $problema = if ($rc -ne 0) { "pg_dump saiu com código $rc" } else { Confirmar-Dump $b.Cont $cru }

        if ($problema) {
            Falha "$($b.Cont)/$base — $problema"
            if (Test-Path "$cru.err") { Get-Content "$cru.err" -TotalCount 3 | ForEach-Object { Diga "        $_" } }
            $erros.Add("$($b.Cont)/${base}: $problema")
            Remove-Item $cru -Force -ErrorAction SilentlyContinue
        } else {
            $mb = [math]::Round((Get-Item $cru).Length / 1MB, 2)
            Cifrar $cru "$cru.age"
            Ok "$($b.Cont)/$base — $mb MB, conferido e cifrado"
            $feitos++
        }
        Remove-Item "$cru.err" -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 2. A MÍDIA (MinIO) — os arquivos que o sigma_midia só INDEXA.
#
# ⚠️ Sem isto o backup do banco seria uma mentira útil: as linhas voltariam
# apontando para objetos que não existem mais, e cada imagem do catálogo viraria
# um 404. O banco sabe o NOME do arquivo; quem tem o arquivo é o MinIO.
# ---------------------------------------------------------------------------
if (-not $SemMidia -and -not $Apenas) {
    Passo "Mídia (MinIO)"
    $vivo = (& docker ps --filter ('name=^/sigma-midia-minio' + '$') --format '{{.Names}}' 2>$null)
    if (-not $vivo) {
        Falha "sigma-midia-minio não está em pé — a mídia NÃO foi salva"
        $erros.Add("minio: contêiner fora do ar")
    } else {
        # 🐞 `docker cp`, e NÃO `docker exec ... tar`.
        #
        # A imagem do MinIO é mínima: não tem `tar` nem `find`. O primeiro
        # `docker exec tar -czf -` produziu arquivo vazio, e isso só apareceu
        # porque a guarda de tamanho o pegou — sozinho, teria deixado um
        # `midia.tgz` de 0 byte com toda a cara de backup.
        #
        # `docker cp` é executado pelo DAEMON, que lê o sistema de arquivos do
        # contêiner por fora. É exatamente onde ele difere do `kubectl cp`, que
        # roda `tar` DENTRO do destino e falha calado nesta mesma imagem.
        $tmpM = Join-Path $env:TEMP "midia-$carimbo"
        Remove-Item $tmpM -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $tmpM -Force | Out-Null

        & cmd.exe /c "docker cp sigma-midia-minio:/data `"$tmpM`" >nul 2>&1"
        $copiados = @(Get-ChildItem $tmpM -Recurse -File -ErrorAction SilentlyContinue).Count

        if ($copiados -eq 0) {
            Falha "o docker cp da mídia não trouxe arquivo nenhum"
            $erros.Add("minio: docker cp vazio")
        } else {
            $zip = Join-Path $pasta 'midia.zip'
            Compress-Archive -Path "$tmpM\*" -DestinationPath $zip -Force
            $mb = [math]::Round((Get-Item $zip).Length / 1MB, 2)
            Cifrar $zip "$zip.age"
            Ok "mídia — $copiados arquivo(s), $mb MB, cifrada"
            $feitos++
        }
        Remove-Item $tmpM -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 3. OS SEGREDOS (.env)
#
# São o que NÃO se reconstrói: chave de ciframento de token, segredo do
# Keycloak, credencial de adquirente. Um banco sem eles restaura para uma
# aplicação que não sobe.
# ---------------------------------------------------------------------------
if (-not $Apenas) {
    Passo "Segredos (.env)"
    $raiz = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent   # ...\Workspace
    $tmp  = Join-Path $env:TEMP "segredos-$carimbo"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $n = 0
    foreach ($proj in (Get-ChildItem $raiz -Directory)) {
        foreach ($f in (Get-ChildItem $proj.FullName -Filter '.env*' -File -Depth 1 -ErrorAction SilentlyContinue)) {
            if ($f.Name -match '\.(example|sample|template)$') { continue }
            $alvo = Join-Path $tmp "$($proj.Name)__$($f.Name)"
            Copy-Item $f.FullName $alvo -Force
            $n++
        }
    }
    if ($n -eq 0) {
        Falha "nenhum .env encontrado — isso quase certamente é um erro do script"
        $erros.Add("segredos: nenhum arquivo coletado")
    } else {
        $zip = Join-Path $pasta 'segredos.zip'
        Compress-Archive -Path "$tmp\*" -DestinationPath $zip -Force
        Cifrar $zip "$zip.age"
        Ok "segredos — $n arquivo(s), cifrados"
        $feitos++
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 4. O VEREDITO, e a rotação que depende dele.
# ---------------------------------------------------------------------------
Passo "Resultado"

$manifesto = Join-Path $pasta 'MANIFESTO.txt'
$linhas = @("carga: $carimbo", "itens: $feitos", "falhas: $($erros.Count)", "")
Get-ChildItem $pasta -File | Sort-Object Name | ForEach-Object {
    $linhas += ("{0,-52} {1,10:N0} bytes" -f $_.Name, $_.Length)
}
if ($erros.Count) { $linhas += ""; $linhas += "FALHAS:"; $erros | ForEach-Object { $linhas += "  - $_" } }
$linhas | Out-File -FilePath $manifesto -Encoding utf8

$total = [math]::Round(((Get-ChildItem $pasta -File | Measure-Object Length -Sum).Sum / 1MB), 1)
Diga "$feitos item(ns), $total MB"

if ($erros.Count) {
    Write-Host "`n  $($erros.Count) FALHA(S):" -ForegroundColor Red
    $erros | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    # 🐞 A carga ruim NÃO rotaciona. Ver a nota da pasta vazia na cabeça: um
    # backup que falhou não pode empurrar um backup bom para fora.
    Write-Host "`n  A rotação foi PULADA: as cargas antigas ficam onde estão." -ForegroundColor Yellow
    exit 1
}

# Só chega aqui se TUDO passou.
$cargas = Get-ChildItem $Destino -Directory | Sort-Object Name
if ($cargas.Count -gt $ManterCargas) {
    $apagar = $cargas | Select-Object -First ($cargas.Count - $ManterCargas)
    foreach ($c in $apagar) {
        Remove-Item $c.FullName -Recurse -Force
        Diga "rotação: $($c.Name) removida"
    }
}

Write-Host "`n  BACKUP COMPLETO — nenhuma falha." -ForegroundColor Green
Diga "para restaurar, ver estacao/RESTAURAR.md"

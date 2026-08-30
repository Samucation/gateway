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
# ---------------------------------------------------------------------------
# ⚠️ 29/08/2026 — NOVE ENTRADAS SAÍRAM DAQUI, e não por limpeza de estilo.
#
# Elas apontavam para contêineres que não existem mais: aqueles projetos
# migraram para o k3s da distro `prd`. O script reclamava dos nove todas as
# noites, e a reclamação tinha um efeito colateral que ninguém ligou à causa —
# falha PULA A ROTAÇÃO, então as cargas antigas nunca saíam e o G: chegou a 94%.
#
# Quem cuida deles agora é a seção `1b`, que DESCOBRE os bancos perguntando ao
# cluster. Se algum voltar a subir no Docker, esta tabela não vai vê-lo; o
# lugar certo de mexer, nesse dia, é aqui.
#
# Ficaram os quatro que ainda rodam em Docker de verdade — conferido com
# `docker ps` no dia, e não de cabeça.
# ---------------------------------------------------------------------------
$BANCOS = @(
    @{ Cont='liveflow-db';               User='liveflow';   Bases=@('liveflow','liveflow_e2e') }
    @{ Cont='sigma-db';                  User='sigma';      Bases=@('sigma_financeiro','sigma_financeiro_e2e') }
    @{ Cont='sigma-db-sandbox';          User='sigma';      Bases=@('sigma_financeiro_sandbox') }
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
# 1b. OS BANCOS E ARQUIVOS DO K3S — a produção de verdade.
#
# ---------------------------------------------------------------------------
# ⚠️ ISTO FALTAVA, E O BURACO DUROU MESES
# ---------------------------------------------------------------------------
# A tabela `$BANCOS` acima é escrita à mão. Em 29/08/2026, 9 dos 13 contêineres
# dela já não existiam: a produção tinha migrado para o k3s da distro WSL2
# `prd`, e a tabela ficou apontando para fantasmas.
#
# O script era honesto — reclamava de cada ausente. Só que ninguém lê o log de
# uma tarefa das 02:30, e havia um efeito colateral que ninguém ligou à causa:
# como falha PULA A ROTAÇÃO (e isso é proposital, ver o fim do arquivo), as
# cargas antigas nunca eram removidas e o G: chegou a 94%.
#
# O que ninguém via era pior. Os 19 bancos que passaram a existir no k3s não
# estavam na tabela, então não geravam erro nenhum: sem dump, sem falha, sem
# pista. Entre eles o do CARTÓRIO — que guarda pedido de cidadão, candidatura,
# e (com a V27) documento pessoal anexado a solicitação.
#
# ⚠️ Por isso a parte nova NÃO TEM LISTA. Ela pergunta ao cluster quem responde
# como Postgres e faz backup de quem responder. Uma segunda lista à mão
# apodreceria exatamente como a primeira — e a primeira levou meses para ser
# notada.
#
# ⚠️ CUSTO: são ~19 bancos e os volumes de arquivo, todos às 02:30. É leitura,
# mas é leitura em cima da produção. Se um dia pesar, o caminho é escalonar por
# namespace (os dois scripts aceitam o namespace como segundo argumento), e não
# reduzir o que se copia.
# ---------------------------------------------------------------------------
function Invocar-NaDistro($caminhoDoScript, $argumentos) {
    # ⚠️ O script vai por base64, e não pelo caminho `/mnt/e/...`.
    #
    # 🐞 Dois motivos, os dois já custaram tempo nesta casa: o arquivo está num
    # repositório com final de linha CRLF, e `bash` engasga com o `\r` de um
    # jeito que o erro não menciona; e a passagem de argumentos por
    # `wsl -- prog args` é reinterpretada pelo shell da distro antes de chegar
    # ao programa.
    $texto = (Get-Content $caminhoDoScript -Raw -Encoding UTF8) -replace "`r", ""
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($texto))
    $comando = "echo $b64 | base64 -d > /tmp/_bkp.sh; bash /tmp/_bkp.sh $argumentos; rc=`$?; rm -f /tmp/_bkp.sh; exit `$rc"
    return (& wsl -d prd -u root -- bash -lc $comando 2>&1)
}

if (-not $Apenas) {
    Passo "k3s de produção (bancos e arquivos)"

    $destinoWsl = "/mnt/g/Backups/estacao/$carimbo"

    foreach ($etapa in @(
        @{ Nome = 'bancos';   Script = 'exportar-bancos-do-k3s.sh' },
        @{ Nome = 'arquivos'; Script = 'exportar-arquivos-do-k3s.sh' }
    )) {
        $script = Join-Path $PSScriptRoot $etapa.Script
        if (-not (Test-Path $script)) {
            Falha "$($etapa.Script) não encontrado — o k3s NÃO foi salvo"
            $erros.Add("k3s/$($etapa.Nome): script ausente")
            continue
        }

        $saida = Invocar-NaDistro $script $destinoWsl

        foreach ($linha in $saida) {
            $campos = "$linha".Split('|')
            switch ($campos[0]) {
                'OK'     { Ok ("k3s " + $campos[1] + $(if ($campos.Count -gt 3) { " — " + $campos[3] } else { "" })); $feitos++ }
                'FALHA'  { Falha ("k3s " + $campos[1]); $erros.Add("k3s: $($campos[1])") }
                'PULADO' { Diga ("pulado: " + $campos[1]) }
                'RESUMO' { Diga ("$($etapa.Nome): $($campos[1]) copiado(s), $($campos[2]) falha(s), $($campos[3]) pulado(s)") }
            }
        }
    }

    # ⚠️ Cifra o que veio do k3s. Sem isto os dumps de produção ficariam em CLARO
    # no disco externo, ao lado dos que são cifrados — e a diferença não estaria
    # em lugar nenhum além deste comentário.
    foreach ($cru in (Get-ChildItem $pasta -File | Where-Object {
                          $_.Name -like '*.dump' -or $_.Name -like '*.tar.gz' })) {
        Cifrar $cru.FullName "$($cru.FullName).age"
    }
}

# ---------------------------------------------------------------------------
# 2. A MÍDIA (MinIO) — APOSENTADA EM 29/08/2026, e não removida por limpeza.
#
# Esta seção procurava o contêiner `sigma-midia-minio` no DOCKER. Ele não
# existe mais lá: o MinIO foi para o k3s junto com o resto da produção, e a
# seção passou a falhar todas as noites — sendo, sozinha, a razão de o backup
# sair com código 1 e a rotação nunca rodar.
#
# ⚠️ O acervo NÃO ficou descoberto: quem o copia agora é a seção `1b`, que
# empacota o volume `sigma-midia/objetos-sigma-midia-minio-0` direto do
# cluster (medido: 928 arquivos, 53,6 MB).
#
# ⚠️ E o problema que o comentário antigo registrava continua verdadeiro e
# continua tratado: a imagem do MinIO não tem `tar`, então `kubectl cp` falha
# calado nela. A solução de lá era `docker cp`, que o daemon executa por fora;
# a de agora é subir um Pod auxiliar que monta o MESMO volume em modo somente
# leitura e traz as ferramentas. Vale para o MinIO e para qualquer imagem
# mínima que apareça depois — ver `exportar-arquivos-do-k3s.sh`.
#
# O parâmetro `-SemMidia` continua aceito para não quebrar quem o usa em
# script, e hoje não faz nada.
# ---------------------------------------------------------------------------

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

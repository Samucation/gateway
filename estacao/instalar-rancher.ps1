<#
.SYNOPSIS
Instala o Rancher — o painel de administração dos clusters — num cluster k3s/k3d.

.DESCRIPTION
⚠️ LEIA `estacao\rancher-hmg.yaml` ANTES. O custo de memória, a escolha de TLS e
o motivo de começar pela homologação estão explicados lá, no ponto onde mordem.

O que este script faz e o manifesto não faz: a SENHA INICIAL. Ela é gerada aqui
e vira um Secret no cluster, em vez de ficar no YAML — YAML está no Git.

⚠️ O Rancher procura o Secret `bootstrap-secret` no namespace `cattle-system` e
usa o que estiver lá. Criá-lo ANTES do gráfico é o que permite escolher a senha
sem passá-la por linha de comando do Helm (onde ela apareceria no objeto
HelmChart, que por sua vez fica legível para quem lê o cluster).

.PARAMETER Contexto
Qual cluster. Padrão `k3d-hmg` (homologação desta estação).

⚠️ Para produção o contexto é outro E a escolha de TLS muda — ver o cabeçalho
do `rancher-hmg.yaml`. Não aponte este script para produção sem ler aquilo.

.EXAMPLE
.\estacao\instalar-rancher.ps1
.\estacao\instalar-rancher.ps1 -Contexto k3d-hmg
#>
[CmdletBinding()]
param(
    [string]$Contexto = 'k3d-hmg',
    [string]$Hostname  = 'rancher.hmg',
    [int]$PortaEntrada = 8090
)

# 🐞 `Continue`, e nao `Stop`: no PowerShell 5.1 a saida de erro de um programa
# externo vira ErrorRecord, e um `kubectl get` de coisa que ainda nao existe
# mataria o script. Mesma armadilha ja documentada em `segredos-hmg.ps1`.
$ErrorActionPreference = 'Continue'

$raiz      = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifesto = Join-Path $raiz 'rancher-hmg.yaml'
# ⚠️ FORA do repositorio. Este arquivo tem a senha do painel que administra o
# cluster; dentro do repo, um `git add` distraido a publica.
$guardada  = Join-Path $env:USERPROFILE '.rancher-senha-hmg.txt'

function Passo($t) { Write-Host "==> $t" -ForegroundColor Cyan }
function Diga($t)  { Write-Host "    $t" }

# ---- 0. o cluster responde? ----------------------------------------------
& kubectl --context $Contexto get --raw /readyz *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "O contexto '$Contexto' nao responde. Suba o cluster antes." -ForegroundColor Red
    exit 1
}

# ⚠️ Guarda de ambiente. O `montar-hmg.ps1` deste projeto ja teve um irmao que
# aplicou overlay de homologacao no cluster de PRODUCAO por confiar no nome do
# contexto -- e o Ingress do Urupix voltou para `urupix.hmg`, com o dominio
# publico em 404 e a aplicacao de pe. Aqui a conferencia e barata: producao roda
# na distro WSL e nunca tem no com prefixo `k3d-`.
$nos = (& kubectl --context $Contexto get nodes -o jsonpath='{.items[*].metadata.name}' 2>$null)
Diga "nos: $nos"
if ($Contexto -like 'k3d-*' -and "$nos" -notlike '*k3d-*') {
    Write-Host "RECUSADO: o contexto diz k3d mas o no nao e de k3d. Confira antes." -ForegroundColor Red
    exit 1
}

# ---- 1. a senha inicial ---------------------------------------------------
Passo 'senha inicial'
& kubectl --context $Contexto create namespace cattle-system *> $null

& kubectl --context $Contexto get secret bootstrap-secret -n cattle-system *> $null
if ($LASTEXITCODE -eq 0) {
    Diga 'bootstrap-secret ja existe -- mantido'
    Diga "(se perdeu a senha, a copia esta em $guardada)"
} else {
    # 12 bytes -> 24 hex. Sem simbolo de proposito: esta senha e digitada a mao
    # numa tela de login, e caractere ambiguo em fonte de terminal ja custou
    # tempo antes.
    $bytes = New-Object byte[] 12
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $senha = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''

    & kubectl --context $Contexto create secret generic bootstrap-secret `
        -n cattle-system --from-literal=bootstrapPassword=$senha *> $null
    if ($LASTEXITCODE -ne 0) { Write-Host 'falhou ao criar o Secret' -ForegroundColor Red; exit 1 }

    "usuario: admin`nsenha:   $senha`ncluster: $Contexto`nurl:     http://${Hostname}/" |
        Set-Content -Path $guardada -Encoding utf8
    # ⚠️ Aspas simples em volta de admin, e NAO crase: dentro de string com
    # aspas duplas a crase e o caractere de ESCAPE do PowerShell. `admin` fazia
    # a crase final escapar a propria aspa de fechamento, e o arquivo inteiro
    # deixava de compilar -- com o erro apontando 70 linhas adiante.
    Diga "gerada -- usuario 'admin'"
    Write-Host "    SENHA: $senha" -ForegroundColor Yellow
    Diga "copia em $guardada"
}

# ---- 2. o grafico ---------------------------------------------------------
Passo 'aplicando o manifesto'
& kubectl --context $Contexto apply -f $manifesto
if ($LASTEXITCODE -ne 0) { Write-Host 'falhou o apply' -ForegroundColor Red; exit 1 }

# ---- 3. esperar ----------------------------------------------------------
#
# ⚠️ Duas esperas, e nao uma. O controlador do k3s primeiro roda um Job que
# executa o `helm install`; so DEPOIS o Deployment passa a existir. Esperar o
# Deployment direto falha em "not found" nos primeiros minutos -- que parece
# instalacao quebrada e e so ordem de acontecimento.
Passo 'esperando o Job do Helm criar o Deployment'
$existe = $false
foreach ($i in 1..60) {
    & kubectl --context $Contexto get deploy rancher -n cattle-system *> $null
    if ($LASTEXITCODE -eq 0) { $existe = $true; Diga "apareceu (tentativa $i)"; break }
    Start-Sleep -Seconds 10
}
if (-not $existe) {
    Write-Host 'o Deployment nao apareceu em 10 min.' -ForegroundColor Red
    Diga 'olhe o Job:  kubectl -n kube-system logs job/helm-install-rancher'
    exit 1
}

Passo 'esperando o Rancher ficar pronto'
& kubectl --context $Contexto -n cattle-system rollout status deploy/rancher --timeout=900s
if ($LASTEXITCODE -ne 0) {
    Write-Host 'o rollout nao completou.' -ForegroundColor Red
    Diga "kubectl --context $Contexto -n cattle-system describe pod -l app=rancher"
    exit 1
}

# ---- 4. a prova ----------------------------------------------------------
#
# ⚠️ `rollout status` verde NAO e "o painel abre". Ele diz que o Pod subiu, nao
# que o Ingress roteia. Esta casa ja teve cluster inteiro verde com nada
# respondendo (o `--disable=servicelb` do k3d-hmg.yaml). A prova e a resposta
# HTTP pela porta de entrada, com o Host certo.
Passo 'provando pela entrada'
$codigo = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 20 `
    -H "Host: $Hostname" "http://127.0.0.1:$PortaEntrada/" 2>$null)
Diga "http://127.0.0.1:$PortaEntrada/ (Host: $Hostname) -> $codigo"

if ($codigo -match '^(200|302|301)$') {
    Write-Host ''
    Write-Host 'Rancher no ar.' -ForegroundColor Green
    Write-Host "  http://127.0.0.1:$PortaEntrada/   com o cabecalho Host: $Hostname"
    Write-Host "  ou acrescente '127.0.0.1 $Hostname' ao arquivo hosts do Windows"
    Write-Host "  e abra http://${Hostname}:$PortaEntrada/"
    exit 0
}

Write-Host ''
Write-Host "O Pod subiu mas a entrada devolveu $codigo." -ForegroundColor Yellow
Diga "Confira o Ingress:  kubectl --context $Contexto -n cattle-system get ingress"
exit 1

<#
.SYNOPSIS
Faz a produção passar do Docker para o k3s da distro `prd` — e volta.

.DESCRIPTION
===========================================================================
⚠️ RODE COMO ADMINISTRADOR.
===========================================================================

    .\CORTAR-PARA-K3S.ps1 -Conferir     # não muda nada; só mede
    .\CORTAR-PARA-K3S.ps1 -Para k3s
    .\CORTAR-PARA-K3S.ps1 -Para docker  # a volta

===========================================================================
POR QUE PRECISA DE ADMINISTRADOR (e por que eu não fiz sozinho)
===========================================================================
Três coisas aqui exigem elevação, e todas são de sistema:

  1. parar/subir o serviço do túnel (`NerdQuizTunnel`);
  2. `netsh interface portproxy`, que liga a porta do Windows à distro;
  3. registrar a tarefa de inicialização.

Sem elevação o script pararia no meio — com o túnel já apontando para um lado
e o serviço ainda no outro. Meio-caminho é o pior estado de uma virada.

===========================================================================
🐞 O `localhost` DO WSL2 NÃO ATRAVESSA DO WINDOWS PARA A DISTRO
===========================================================================
Medido nesta máquina, três vezes:

    do Windows → localhost:32000 (registro no k3s)   ❌
    do Windows → <ip-da-distro>:32000                ✅ 200
    do Windows → <ip-da-distro>:80  (Traefik)        ✅ 200

O túnel roda NO WINDOWS. Apontá-lo para `localhost` não funcionaria, e o erro
apareceria como 502 — com cara de aplicação fora do ar, quando o que falta é
o caminho até ela.

⚠️ E o IP da distro MUDA a cada partida (rede NAT do WSL). Por isso o
mapeamento é refeito aqui e na tarefa de boot, e não configurado uma vez.
#>
[CmdletBinding()]
param(
    [ValidateSet('k3s', 'docker')][string]$Para = '',
    [switch]$Conferir,
    [string]$Distro = 'prd',
    [string]$Config = "$env:USERPROFILE\.cloudflared\config.yml"
)

$ErrorActionPreference = 'Continue'
function Diga($t) { Write-Host "  $t" }

# Os dominios que o `config.yml` sabe atender.
$DOMINIOS = @(
    'urupix.com.br', 'www.urupix.com.br', 'urupix.cursodetecnologia.dev.br',
    'sprinklegames.com.br', 'www.sprinklegames.com.br',
    'opuschat.cursodetecnologia.dev.br', 'cafe-api.cursodetecnologia.dev.br',
    'sigma-financeiro.cursodetecnologia.dev.br',
    'sigma-midia.cursodetecnologia.dev.br',
    'central-ia.cursodetecnologia.dev.br',
    'veltrixa.cursodetecnologia.dev.br',
    'quiz.cursodetecnologia.dev.br', 'api.cursodetecnologia.dev.br'
)

function IpDaDistro {
    # 🐞 `hostname -I`, e nao `ip addr | awk`.
    #
    # A primeira versao usava `awk '{print $4}'` dentro de uma string do
    # PowerShell. O `$4` do awk e variavel para o PowerShell tambem: ele o
    # trocava por VAZIO antes de mandar, e o comando devolvia a linha inteira
    # da interface em vez do endereco. O script entao dizia
    # "NAO DESCOBERTO" -- com a rede funcionando perfeitamente.
    #
    # ⚠️ Cifrao dentro de string de PowerShell que vai virar comando de shell
    # e sempre suspeito. `hostname -I` nao usa nenhum.
    $saida = (& wsl.exe -d $Distro -u root -- hostname -I 2>$null)
    $ip = ("$saida" -replace "`0", '' -replace "`r", '').Trim()
    # A primeira e a da eth0; as demais sao docker/cni internas.
    if ($ip -match '^(\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }
    return $null
}

function MedirDominios {
    $fora = @()
    foreach ($d in $DOMINIOS) {
        $c = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 15 "https://$d/" 2>$null)
        if ($c -in @('000', '502', '530')) { $fora += "$d -> $c" }
    }
    return $fora
}

function ExigirAdmin {
    $eu = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $eu.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error 'Precisa de PowerShell como Administrador.'
        exit 3
    }
}

# ---------------------------------------------------------------- conferir
if ($Conferir -or -not $Para) {
    Diga '== estado atual =='
    $ip = IpDaDistro
    Diga "ip da distro: $(if ($ip) { $ip } else { 'NAO DESCOBERTO' })"
    Diga "conteineres docker: $((& docker ps --format '{{.Names}}' 2>$null | Measure-Object).Count)"
    # ⚠️ A saida do `wsl.exe` vem com bytes nulos entre os caracteres (UTF-16).
    # Sem limpar, o `-split` devolve UMA linha gigante e a contagem da 1.
    $pods = ((& wsl.exe -d $Distro -u root -- kubectl get pods -A --no-headers 2>$null) `
             -join "`n") -replace "`0", ''
    $n = ($pods -split "`n" | Where-Object { $_ -match '\bRunning\b' } | Measure-Object).Count
    Diga "pods Running no k3s: $n"
    if ($ip) {
        $c = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 10 -H 'Host: urupix.com.br' "http://${ip}/" 2>$null)
        Diga "k3s responde urupix.com.br: $c"
    }
    $fora = MedirDominios
    Diga "dominios fora: $($fora.Count) de $($DOMINIOS.Count)"
    $fora | ForEach-Object { Diga "   $_" }
    exit 0
}

ExigirAdmin

# ---------------------------------------------------------------- para o k3s
if ($Para -eq 'k3s') {
    Diga '== 1. conferindo o k3s ANTES de mexer no que funciona =='
    $ip = IpDaDistro
    if (-not $ip) { Write-Error 'nao descobri o IP da distro; abortando'; exit 1 }
    $c = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 10 -H 'Host: urupix.com.br' "http://${ip}/" 2>$null)
    if ($c -ne '200') {
        # ⚠️ Recusa ANTES de derrubar o Docker. Cortar para um destino que nao
        # responde troca uma producao viva por nenhuma.
        Write-Error "o k3s nao esta atendendo (urupix devolveu $c). Nao vou cortar."
        exit 1
    }
    Diga "k3s atendendo em $ip (urupix 200)"

    Diga '== 2. ligando as portas do Windows a distro =='
    foreach ($p in 80, 8050) {
        & netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=$p 2>&1 | Out-Null
        & netsh interface portproxy add v4tov4 listenaddress=127.0.0.1 listenport=$p connectaddress=$ip connectport=$p 2>&1 | Out-Null
    }
    Diga "127.0.0.1:80 e :8050 -> $ip"

    Diga '== 3. congelando a origem =='
    # ⚠️ PARAR ANTES DE COPIAR, e nao depois.
    #
    # 🐞 Enquanto o Docker atende, as tabelas de auditoria crescem: cada
    # conferencia acusava `ApiAccessLog` e `msg_audit` com uma linha a mais no
    # lado antigo. Nao e perda -- e que o dump e um retrato, e o original
    # continua se mexendo.
    #
    # A copia definitiva so vale com a origem congelada. Por isso os apps
    # param aqui, ANTES da ultima passada de dados.
    & docker stop gateway-kong 2>&1 | Out-Null
    foreach ($c in (& docker ps --format '{{.Names}}' 2>$null)) {
        # Os BANCOS ficam de pe: e deles que a copia final sai.
        if ($c -match 'postgres|db$|-db|redis|minio|kafka|redpanda') { continue }
        & docker stop $c 2>&1 | Out-Null
    }
    Diga 'aplicacoes do docker paradas (bancos seguem de pe para a copia)'

    Diga '== 4. copia final dos dados, com a origem parada =='
    & bash "$PSScriptRoot/migrar-dados.sh" 2>&1 | Select-String '✅|❌|⚠️|problema' |
        ForEach-Object { Diga "   $_" }

    Diga '== 5. tarefa de inicializacao =='
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\subir-no-boot.ps1" -Instalar

    Diga '== 6. conferindo o que o usuario ve =='
    Start-Sleep -Seconds 20
    $fora = MedirDominios
    if ($fora.Count -eq 0) {
        Diga '✅ producao no k3s, todos os dominios atendendo.'
    } else {
        Diga "⚠️ $($fora.Count) dominio(s) fora:"
        $fora | ForEach-Object { Diga "   $_" }
        Diga ''
        Diga 'Para voltar:  .\CORTAR-PARA-K3S.ps1 -Para docker'
    }
    exit $fora.Count
}

# ---------------------------------------------------------------- a volta
if ($Para -eq 'docker') {
    Diga '== desfazendo: producao de volta ao Docker =='
    foreach ($p in 80, 8050) {
        & netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=$p 2>&1 | Out-Null
    }
    Diga 'encaminhamento de portas removido'
    # ⚠️ `start` de todos os parados, e nao `compose up` de um arquivo so: os
    # conteineres vem de composes diferentes, espalhados pelos repositorios.
    & docker start gateway-kong 2>&1 | Out-Null
    foreach ($c in (& docker ps -a --filter status=exited --format '{{.Names}}' 2>$null)) {
        & docker start $c 2>&1 | Out-Null
    }
    Diga 'conteineres do docker religados'
    Start-Sleep -Seconds 25
    $fora = MedirDominios
    Diga "dominios fora: $($fora.Count)"
    $fora | ForEach-Object { Diga "   $_" }
    exit $fora.Count
}

<#
.SYNOPSIS
Sobe a distro de produção no boot e refaz o encaminhamento de portas.

.DESCRIPTION
===========================================================================
⚠️ O WSL2 **NÃO** SOBE SOZINHO COM O WINDOWS
===========================================================================
Sem esta tarefa, um reinício deixa a produção no chão **em silêncio**: os
domínios respondem 530, o Windows está normal, e nada no Visualizador de
Eventos aponta para a causa. É o pior tipo de queda — a que não se anuncia.

===========================================================================
🐞 E O `localhost` DO WSL2 NÃO ATRAVESSA NOS DOIS SENTIDOS
===========================================================================
Medido em 23/08/2026, nesta máquina:

    de dentro da distro → localhost do Windows     ✅
    do Windows          → localhost:32000 da distro ❌
    do Windows          → IP da distro:32000        ✅ 200

O túnel do Cloudflare roda **no Windows** e precisa alcançar o Kong que está
lá dentro. Como o `localhost` não atravessa, entra o `portproxy`: ele mapeia
`127.0.0.1:PORTA` do Windows para o IP da distro.

⚠️ E o IP da distro **muda a cada partida** (a rede do WSL é NAT). Por isso o
mapeamento é REFEITO aqui, no boot, em vez de configurado uma vez à mão — que
funcionaria até o primeiro reinício e falharia depois, parecendo outro
problema.

.PARAMETER Instalar
Cria (ou recria) a tarefa agendada. Precisa de Administrador.

.EXAMPLE
.\subir-no-boot.ps1 -Instalar
.\subir-no-boot.ps1              # executa agora, uma vez
#>
[CmdletBinding()]
param(
    [switch]$Instalar,
    [string]$Distro = 'prd',
    # 8050 = Kong (a entrada da produção). 32000 = registro de imagens.
    # 8080 = Jenkins.
    [int[]]$Portas = @(8050, 32000, 8080)
)

$ErrorActionPreference = 'Stop'
$EU = $MyInvocation.MyCommand.Path

function Diga($t) { Write-Host "  $t" }

# ---------------------------------------------------------------------------
function Instalar-Tarefa {
    $eu = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $eu.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error 'Precisa de PowerShell como Administrador para criar a tarefa.'
        exit 3
    }

    $acao = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$EU`""
    # ⚠️ `AtStartup`, e não `AtLogOn`: a produção tem que subir mesmo que
    # ninguém faça login na máquina.
    $gatilho = New-ScheduledTaskTrigger -AtStartup
    $conf = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    Register-ScheduledTask -TaskName 'ProducaoWSL' -Action $acao -Trigger $gatilho `
        -Settings $conf -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    Diga 'tarefa `ProducaoWSL` criada (SYSTEM, na inicializacao)'
}

# ---------------------------------------------------------------------------
function Subir-Distro {
    Diga "subindo a distro '$Distro'..."

    # -----------------------------------------------------------------------
    # 🐞 UM COMANDO NAO BASTA — E ESTE DEFEITO CUSTOU HORAS
    # -----------------------------------------------------------------------
    # A versao anterior rodava `wsl -d prd -- /bin/true`, no entendimento de
    # que `systemd=true` mantinha a distro de pe sozinha. NAO mantem: o WSL
    # encerra a distro poucos segundos depois que o ULTIMO processo iniciado
    # de fora termina.
    #
    # O efeito era cruel de diagnosticar. O k3s leva mais de 30 segundos para
    # ficar pronto; a distro morria antes disso e reiniciava no comando
    # seguinte. No log, o k3s aparecia sempre no MESMO ponto
    # ("Reconciling bootstrap data") e `systemctl` dizia `activating` para
    # sempre -- com cara de k3s travado, quando o travado era o ambiente
    # embaixo dele.
    #
    # ⚠️ O `sleep infinity` em segundo plano e o que segura. Enquanto ele
    # viver, a distro vive.
    Start-Process -FilePath 'wsl.exe' `
        -ArgumentList '-d', $Distro, '-u', 'root', '--', 'sleep', 'infinity' `
        -WindowStyle Hidden
    Start-Sleep -Seconds 3

    # Espera o k3s responder de verdade. "A distro subiu" não é a mesma coisa
    # que "o cluster atende" — e é a segunda que importa.
    foreach ($i in 1..60) {
        $r = (& wsl.exe -d $Distro -u root -- bash -c 'k3s kubectl get --raw /readyz 2>/dev/null' 2>$null)
        if ("$r" -match 'ok') { Diga "k3s pronto (tentativa $i)"; return $true }
        Start-Sleep -Seconds 5
    }
    Diga 'k3s NAO respondeu em 5 min'
    return $false
}

# ---------------------------------------------------------------------------
function Refazer-Portas {
    # 🐞 `hostname -I`, e nao `ip addr | awk`.
    #
    # O `$4` do awk e variavel para o PowerShell tambem: ele o trocava por
    # VAZIO antes de mandar o comando, e o awk reclamava `{print \}`. O script
    # concluia "NAO descobri o IP" com a rede perfeita.
    #
    # ⚠️ Cifrao dentro de string do PowerShell que vira comando de shell e
    # sempre suspeito. `hostname -I` nao usa nenhum.
    $ip = (& wsl.exe -d $Distro -u root -- hostname -I 2>$null)
    $ip = ("$ip" -replace "`0", '' -replace "`r", '').Trim()
    # A primeira e a da eth0; as demais sao redes internas do cluster.
    if ($ip -match '^(\d+\.\d+\.\d+\.\d+)') { $ip = $Matches[1] }
    if (-not ($ip -match '^\d+\.\d+\.\d+\.\d+$')) {
        Diga "NAO descobri o IP da distro (veio '$ip')"
        return $false
    }
    Diga "IP da distro: $ip"

    foreach ($p in $Portas) {
        # ⚠️ Apaga ANTES de criar. `add` sobre um mapeamento existente falha, e
        # o erro é fácil de ignorar num script de boot — deixando o
        # encaminhamento apontando para o IP de ontem.
        & netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=$p 2>&1 | Out-Null
        & netsh interface portproxy add v4tov4 listenaddress=127.0.0.1 listenport=$p `
            connectaddress=$ip connectport=$p 2>&1 | Out-Null
    }

    # 🐞 CONFERE que o mapeamento EXISTE, em vez de anunciar que criou.
    #
    # `netsh portproxy add` exige Administrador e, sem ele, falha em SILENCIO
    # -- ainda mais com a saida mandada para o vazio. A versao anterior
    # imprimia "127.0.0.1:8050 -> 172.29.89.49:8050" com a tabela vazia.
    #
    # ⚠️ Guarda que anuncia sucesso sem medir e pior que guarda nenhuma: numa
    # tarefa de boot, ela transformaria "a producao nao esta acessivel" em
    # "tudo certo" no log.
    $tabela = (& netsh interface portproxy show v4tov4 2>&1 | Out-String)
    $faltando = @()
    foreach ($p in $Portas) {
        if ($tabela -match "127\.0\.0\.1\s+$p\s+$([regex]::Escape($ip))\s+$p") {
            Diga "127.0.0.1:$p -> ${ip}:$p"
        } else {
            $faltando += $p
        }
    }
    if ($faltando.Count) {
        Diga "⚠️ NAO consegui mapear: $($faltando -join ', ') (precisa de Administrador)"
        return $false
    }
    return $true
}

# ---------------------------------------------------------------------------
if ($Instalar) { Instalar-Tarefa; exit 0 }

Diga "== producao WSL, $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =="
$ok = Subir-Distro
$ok = (Refazer-Portas) -and $ok

# A prova final é o que o usuário veria: o Kong respondendo pela porta do
# Windows. Serviço "Running" já mentiu antes.
$c = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 10 -H 'Host: urupix.com.br' http://127.0.0.1:8050/ 2>$null)
Diga "kong pela porta do Windows: $c"

if (-not $ok) { exit 1 }
exit 0

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
    # Basta um comando: com `systemd=true` no `wsl.conf`, o systemd assume como
    # PID 1 e a distro permanece de pé.
    & wsl.exe -d $Distro -u root -- /bin/true 2>&1 | Out-Null

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
    $ip = (& wsl.exe -d $Distro -u root -- bash -c "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1" 2>$null)
    $ip = "$ip".Trim() -replace "`0", ''
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
        Diga "127.0.0.1:$p -> ${ip}:$p"
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

<#
.SYNOPSIS
Garante que o `sleep infinity` que segura a distro de producao esta VIVO.

.DESCRIPTION
===========================================================================
🐞 SUBIR NO BOOT NAO BASTA -- O KEEPALIVE MORRE NO MEIO DO DIA
===========================================================================
A `subir-no-boot.ps1` roda `At system start up` e dispara um
`wsl -d prd -u root -- sleep infinity`. Enquanto esse processo viver, o WSL
nao encerra a distro (ver `segurar-a-distro.cmd`).

Medido em 04/09/2026: a tarefa de boot TINHA rodado -- a tabela de
`portproxy` estava certa, com as quatro portas apontando para o IP daquela
partida, coisa que so ela escreve. Mesmo assim **nao havia nenhum
`sleep infinity`**: ele morreu em algum momento do dia e ninguem refez.

O resultado foi a distro sendo encerrada por ociosidade as 23:24 e voltando
so as 23:55 -- 31 minutos com TODOS os dominios fora, e no log apenas
"Reached target shutdown.target". Nao ha erro, nao ha crash: o systemd para
o k3s LIMPO. Ver [[regra-wsl-mata-distro-ociosa]].

⚠️ Gatilho de boot e um TIRO UNICO. O que o problema pedia era um VIGIA:
algo que confira periodicamente e refaca. E o que este script faz.

⚠️ Ele tambem serve de keepalive por si so: consultar a distro ja a acorda.
Mas o que segura de verdade e o `sleep infinity` que ele (re)inicia.

.EXAMPLE
.\vigia-do-keepalive.ps1              # confere e refaz se preciso
.\vigia-do-keepalive.ps1 -Instalar    # cria a tarefa (NAO precisa de Admin)
#>
[CmdletBinding()]
param(
    [switch]$Instalar,
    [string]$Distro = 'prd',
    [int]$MinutosEntreConferencias = 5
)

$EU = $MyInvocation.MyCommand.Path

function Instalar-Tarefa {
    # ⚠️ Sem `-RunLevel Highest` e sem `-User SYSTEM`: os dois exigem elevacao
    # e falham com "Access is denied". Esta tarefa nao precisa de nenhum dos
    # dois -- segurar a distro nao pede privilegio.
    $acao = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$EU`""

    $gatilho = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

    # A REPETICAO e o ponto do arquivo. Sem ela isto vira outro tiro unico.
    #
    # ⚠️ NAO usar `[TimeSpan]::MaxValue` como duracao: o Agendador recusa o XML
    # ("P99999999DT23H59M59S ... out of range") e o `Register` estoura. Dez anos
    # e um numero que ele aceita e que, na pratica, e "para sempre".
    $gatilho.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes $MinutosEntreConferencias) `
        -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition

    $conf = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName 'ProducaoWSL-vigia' -Action $acao `
        -Trigger $gatilho -Settings $conf `
        -User "$env:USERDOMAIN\$env:USERNAME" -RunLevel Limited -Force | Out-Null

    # 🐞 CONFERE QUE A TAREFA EXISTE, em vez de anunciar que criou.
    #
    # A primeira versao imprimia "tarefa criada" mesmo depois de o `Register`
    # ter falhado com "task XML ... out of range" -- a mensagem de sucesso saiu
    # logo abaixo do erro. Guarda que anuncia sem medir e pior que guarda
    # nenhuma: aqui ela diria que a producao esta vigiada, e nao estaria.
    $t = Get-ScheduledTask -TaskName 'ProducaoWSL-vigia' -ErrorAction SilentlyContinue
    if (-not $t) {
        Write-Error "NAO consegui criar a tarefa 'ProducaoWSL-vigia'."
        exit 1
    }
    $intervalo = $t.Triggers[0].Repetition.Interval
    if (-not $intervalo) {
        Write-Error "tarefa criada SEM repeticao -- viraria um tiro unico."
        exit 1
    }
    Write-Host "  tarefa 'ProducaoWSL-vigia' criada e conferida (repeticao: $intervalo)"
}

if ($Instalar) { Instalar-Tarefa; exit 0 }

# ---------------------------------------------------------------------------
# 🐞 CONFERE O EFEITO, e nao o registro: pergunta a distro se o processo esta
# la. `Get-Process wsl` no Windows nao serve -- ha varios `wsl.exe` de outras
# coisas, e nenhum deles diz o que roda LA DENTRO.
$vivo = (& wsl.exe -d $Distro -u root -- pgrep -c -f 'sleep infinity' 2>$null)
$vivo = ("$vivo" -replace "[^\d]", '')
if (-not $vivo) { $vivo = '0' }

if ([int]$vivo -ge 1) {
    Write-Host "  keepalive de pe ($vivo processo(s))"
    exit 0
}

Write-Host "  ⚠️ sem keepalive -- refazendo"
Start-Process -FilePath 'wsl.exe' `
    -ArgumentList '-d', $Distro, '-u', 'root', '--', 'sleep', 'infinity' `
    -WindowStyle Hidden
Start-Sleep -Seconds 3

# Confere que a refeitura PEGOU. Anunciar "refiz" sem medir devolveria
# exatamente o silencio que fez esta queda passar despercebida.
$agora = (& wsl.exe -d $Distro -u root -- pgrep -c -f 'sleep infinity' 2>$null)
$agora = ("$agora" -replace "[^\d]", '')
if (-not $agora) { $agora = '0' }
if ([int]$agora -ge 1) { Write-Host "  ✅ keepalive restabelecido"; exit 0 }

Write-Host "  ❌ NAO consegui segurar a distro"
exit 1

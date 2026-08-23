<#
.SYNOPSIS
Recupera o WSL e o Docker Desktop depois da queda de 23/08/2026.

.DESCRIPTION
===========================================================================
⚠️ RODE COMO ADMINISTRADOR. É o único passo que falta.
===========================================================================

    Botão direito no PowerShell → "Executar como administrador"
    cd E:\Desenvolvimento\Dev\Workspace\gateway\estacao\prd-wsl
    .\RECUPERAR-AGORA.ps1

---------------------------------------------------------------------------
O QUE ACONTECEU
---------------------------------------------------------------------------
Montando a produção nova em k3s (distro `prd`), o build de imagem esgotou a
memória da máquina virtual do WSL — que é **uma só, compartilhada por todas as
distros**, inclusive a do Docker Desktop.

Para recuperar, rodei `wsl --shutdown`. Foi aí que a coisa piorou, e o erro foi
meu: aquele comando derruba **todas** as distros, e a produção estava rodando
no Docker. Ao voltar, o Docker Desktop não conseguiu remontar o disco de dados:

    wsl.exe --unmount docker_data.vhdx failed:
    The disk failed to detach: Operation not permitted.

Ele entra num laço de recuperação que não sai sozinho. Reiniciar os processos
do Docker Desktop **exige elevação**, e as janelas de UAC não foram aceitas
(você estava dormindo), então parei por aqui em vez de insistir.

---------------------------------------------------------------------------
NADA DE DADO FOI PERDIDO
---------------------------------------------------------------------------
  - Os volumes do Docker estão intactos no disco.
  - O backup completo de hoje 02:35 está em `G:\Backups\estacao` (19 itens,
    conferido, cifrado).
  - O marco da virada está em `gateway/estacao/marcos/`.
  - Nenhum banco foi tocado, migrado ou apagado.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Diga($t) { Write-Host "  $t" }

$eu = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $eu.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Precisa ser Administrador. Abra o PowerShell como administrador e repita.'
    exit 3
}

Diga '== 1. parando tudo do Docker =='
Stop-Service com.docker.service -Force -ErrorAction SilentlyContinue
Get-Process com.docker.backend, 'Docker Desktop', com.docker.build -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

Diga '== 2. reiniciando o WSL =='
# ⚠️ O `wsl --shutdown` sozinho nao bastou: o servico ficou num estado em que
# NENHUMA distro subia ("Catastrophic failure", "CreateInstance/E_FAIL").
# Reiniciar o servico e o que limpa.
& wsl.exe --shutdown 2>&1 | Out-Null
Restart-Service WslService -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 10

Diga '== 3. subindo o Docker Desktop =='
Start-Service com.docker.service -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5
Start-Process 'C:\Program Files\Docker\Docker\Docker Desktop.exe'

Diga '   esperando os conteineres (ate 5 min)...'
$ok = $false
foreach ($i in 1..60) {
    $n = (& docker ps --format '{{.Names}}' 2>$null | Measure-Object).Count
    if ($n -ge 40) { Diga "   $n conteineres de pe"; $ok = $true; break }
    if ($i % 6 -eq 0) { Diga "   ...$n ate agora" }
    Start-Sleep -Seconds 5
}
if (-not $ok) { Diga '   ⚠️ os conteineres NAO voltaram; ver o painel do Docker Desktop' }

Diga ''
Diga '== 4. conferindo os dominios =='
# ⚠️ A prova e o que o usuario ve. "Servico rodando" ja mentiu antes.
$ruins = 0
foreach ($d in 'urupix.com.br', 'quiz.cursodetecnologia.dev.br',
                'sigma-financeiro.cursodetecnologia.dev.br',
                'veltrixa.cursodetecnologia.dev.br') {
    $c = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 15 "https://$d/" 2>$null)
    Diga "   $d -> $c"
    if ($c -eq '000' -or $c -eq '502' -or $c -eq '530') { $ruins++ }
}

Diga ''
if ($ruins -eq 0) {
    Diga '✅ producao de volta.'
} else {
    Diga "⚠️ $ruins dominio(s) ainda fora. O tunel pode precisar de um reinicio:"
    Diga '   Restart-Service NerdQuizTunnel'
}

Diga ''
Diga '---------------------------------------------------------------'
Diga 'NAO suba a distro `prd` antes do Docker estar de pe.'
Diga 'Foi essa ordem que causou a queda: as duas distros dividem UMA'
Diga 'maquina virtual, e a `prd` segurava o disco que o Docker precisa'
Diga 'montar. Com o Docker no ar, `wsl -d prd` e seguro.'
Diga '---------------------------------------------------------------'

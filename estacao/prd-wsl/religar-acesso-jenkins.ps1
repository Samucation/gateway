<#
.SYNOPSIS
Refaz o caminho de fora até o Jenkins e instala a tarefa que sustenta a produção
no boot. PRECISA DE ADMINISTRADOR.

.DESCRIPTION
===========================================================================
O QUE ESTE SCRIPT CONSERTA, E O QUE JÁ FOI FEITO SEM ELE
===========================================================================
Em 28/08/2026 o Jenkins estava de pé (systemd na distro `prd`, respondendo 200
por dentro) e mesmo assim inalcançável, por DOIS motivos independentes:

  1. o acesso PÚBLICO vinha de um túnel próprio (`serverhomol`) que rodava na
     VM. A VM foi desligada em 24/08 e a rota nunca foi refeita aqui;
  2. o acesso LOCAL (`http://localhost:8080`) dependia de um `netsh portproxy`
     que a tarefa de boot deveria refazer — e a tarefa NÃO EXISTIA.

O item 2 é o mais grave, e não é sobre o Jenkins: sem essa tarefa, um reinício
do Windows deixa a PRODUÇÃO INTEIRA no chão em silêncio. Os domínios respondem
530, o Windows está normal, e nada no Visualizador de Eventos aponta a causa.

Já foi feito (não precisa de Administrador, e este script não repete):
  • nginx com senha na frente do Jenkins, na distro   (publicar-jenkins.sh)
  • Jenkins preso em 127.0.0.1                        (drop-in do systemd)
  • URL raiz do Jenkins corrigida
  • a regra do túnel acrescentada ao config.yml       (backup .bak-pre-jenkins-*)

O que falta é só o que exige Administrador — que é o que está aqui.

⚠️ ORDEM IMPORTA: a barreira de senha ANTES do DNS. Ela já está de pé e
provada (401 sem senha, 200 com), então publicar agora é seguro. Se por algum
motivo você rodar isto num ambiente onde a barreira NÃO esteja no ar, o script
recusa — ver o passo 1.

.EXAMPLE
# PowerShell COMO ADMINISTRADOR:
.\estacao\prd-wsl\religar-acesso-jenkins.ps1
#>
[CmdletBinding()]
param(
    [string]$Distro   = 'prd',
    [string]$Dominio  = 'jenkins.cursodetecnologia.dev.br',
    # O túnel que atende a produção. O `serverhomol` (f0d7cd68) morreu com a VM.
    [string]$TunelId  = '47a05dc3-c2d1-4801-bf63-d4cf4bc7a76b',
    [switch]$PularDns
)

$ErrorActionPreference = 'Continue'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path

function Passo($t) { Write-Host "==> $t" -ForegroundColor Cyan }
function Diga($t)  { Write-Host "    $t" }

$eu = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $eu.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Abra o PowerShell COMO ADMINISTRADOR e rode de novo.' -ForegroundColor Red
    Write-Host 'Sem elevacao, `netsh portproxy` e `Register-ScheduledTask` falham em SILENCIO.'
    exit 3
}

# ---------------------------------------------------------------------------
Passo '1. a barreira de senha esta de pe?'
#
# ⚠️ Esta conferencia NAO e burocracia. Publicar o dominio com a barreira fora
# do ar exporia uma tela de login de CI na internet -- e a conta dela e root na
# maquina que roda o Urupix. O 401 aqui e a licenca para seguir.
$semSenha = (& wsl.exe -d $Distro -u root -- curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:8081/login 2>$null)
$semSenha = ("$semSenha" -replace "`0", '').Trim()
Diga "nginx :8081 sem senha -> $semSenha  (tem de ser 401)"
if ($semSenha -ne '401') {
    Write-Host 'RECUSADO: a barreira nao esta barrando. Rode publicar-jenkins.sh antes.' -ForegroundColor Red
    exit 1
}

# E o Jenkins tem de estar FECHADO: se ele ainda escuta fora do loopback, a
# barreira pode ser contornada por quem alcancar a distro.
$bind = (& wsl.exe -d $Distro -u root -- bash -c "ss -ltn | grep ':8080' | awk '{print \$4}' | head -1" 2>$null)
$bind = ("$bind" -replace "`0", '').Trim()
Diga "bind do Jenkins: $bind"
if ($bind -notmatch '127\.0\.0\.1') {
    Write-Host "RECUSADO: o Jenkins escuta em $bind -- a barreira e contornavel." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
Passo '2. a tarefa de boot da producao'
& (Join-Path $raiz 'subir-no-boot.ps1') -Instalar
if ($LASTEXITCODE -ne 0) { Write-Host 'falhou ao criar a tarefa' -ForegroundColor Red }

Passo '3. aplicando o encaminhamento de portas agora'
# Roda a MESMA rotina que a tarefa rodara no boot -- assim o que vale hoje e o
# que valera depois do reinicio. Sao coisas que ja discordaram nesta maquina.
& (Join-Path $raiz 'subir-no-boot.ps1')

$tabela = (& netsh interface portproxy show v4tov4 2>&1 | Out-String)
if ($tabela -notmatch '127\.0\.0\.1\s+8081') {
    Write-Host 'A 8081 NAO entrou na tabela de portproxy.' -ForegroundColor Red
    Diga 'Sem ela o tunel entrega no vazio e o dominio devolve 502.'
    exit 1
}
Diga '8081 mapeada  ✅'

$local = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 10 http://127.0.0.1:8081/login 2>$null)
Diga "http://127.0.0.1:8081/login -> $local  (401 = barreira alcancada pelo Windows)"

# ---------------------------------------------------------------------------
Passo '4. o tunel'
& cloudflared tunnel ingress validate
if ($LASTEXITCODE -ne 0) {
    Write-Host 'O config.yml do tunel NAO validou -- nao vou reiniciar.' -ForegroundColor Red
    Diga 'Ha backup em ~\.cloudflared\config.yml.bak-pre-jenkins-20260828'
    exit 1
}
Restart-Service -Name 'NerdQuizTunnel' -Force
Diga 'NerdQuizTunnel reiniciado; esperando as conexoes voltarem...'
Start-Sleep -Seconds 20

# ⚠️ O watchdog do tunel esta DESABILITADO nesta maquina (medido em 28/08/2026).
# Ele existe porque tunel VIVO mas sem rotear devolve 530 -- e o servico
# aparece "Running". Ver `urupix-tunel-watchdog-sintoma-real`.
$w = Get-ScheduledTask -TaskName 'NerdQuizTunnelWatchdog' -ErrorAction SilentlyContinue
if ($w -and $w.State -eq 'Disabled') {
    Diga '⚠️ NerdQuizTunnelWatchdog esta DESABILITADO -- o tunel esta sem vigia.'
}

# ---------------------------------------------------------------------------
Passo '5. a prova, pela internet'
$codigo = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 30 "https://$Dominio/login" 2>$null)
Diga "https://$Dominio/login -> $codigo"

# 1033 = o CNAME aponta para um tunel que nao esta conectado. Foi o caso do
# `serverhomol`, que morreu junto com a VM e cujo DNS ninguem repontou.
if ($codigo -eq '530' -or $codigo -eq '1033' -or $codigo -eq '000') {
    if ($PularDns) {
        Diga 'DNS parece apontar para o tunel errado, mas -PularDns foi pedido.'
        exit 1
    }
    Passo '5b. repontando o DNS para o tunel vivo'
    # 🐞 `tunnel route dns <NOME>` IGNORA o nome e usa o `tunnel:` do config.yml
    # -- sem avisar. A mensagem de sucesso traz o ID errado no meio, que e facil
    # de nao ler. Por isso passamos o UUID, e conferimos o `tunnelID=` na saida.
    $saida = (& cloudflared tunnel route dns --overwrite-dns $TunelId $Dominio 2>&1 | Out-String)
    Write-Host $saida
    if ($saida -notmatch [regex]::Escape($TunelId)) {
        Write-Host "O DNS pode ter ido para o tunel ERRADO -- confira o tunnelID acima." -ForegroundColor Red
        exit 1
    }
    Start-Sleep -Seconds 15
    $codigo = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 30 "https://$Dominio/login" 2>$null)
    Diga "de novo -> $codigo"
}

Write-Host ''
if ($codigo -eq '401') {
    Write-Host 'Jenkins de volta na internet, atras da senha.' -ForegroundColor Green
    Write-Host "  https://$Dominio/"
    Write-Host '  1a caixa (navegador): usuario `samuel`  -- senha em /root/senha-jenkins-externa.txt na distro'
    Write-Host '  2a tela  (Jenkins):   usuario `samuca`'
    exit 0
}

# ⚠️ 200 aqui seria RUIM: significa que a tela do Jenkins abriu SEM a senha.
if ($codigo -eq '200') {
    Write-Host "🔴 $Dominio respondeu 200 SEM CREDENCIAL." -ForegroundColor Red
    Write-Host '   A barreira nao esta no caminho. Apague o DNS agora e investigue.'
    exit 1
}

Write-Host "Terminou em $codigo -- ver os passos acima." -ForegroundColor Yellow
exit 1

<#
.SYNOPSIS
Vira a produção entre a VM `serverhomol` e ESTA estação — nos dois sentidos.

.DESCRIPTION
===========================================================================
POR QUE ISTO EXISTE
===========================================================================
Em 22/08/2026 a VM foi desligada e os vinte domínios de produção caíram em
`530` — o Cloudflare dizendo que o túnel não tem para onde entregar. A
estação continuava com a pilha antiga de pé e com os dados até o corte de
21/08, então dava para atender daqui. Só que "dava" não é o mesmo que "dá
rápido e sem improviso às duas da manhã".

Este script é a virada ensaiada: um comando para lá, o mesmo comando para cá.

===========================================================================
🔴 O QUE ELE **NÃO** RESOLVE, E VOCÊ PRECISA SABER ANTES DE RODAR
===========================================================================
Os dois lados têm banco PRÓPRIO. Virar não copia dado nenhum.

Desde o corte de 21/08 os domínios atenderam PELA VM, então doações e
cadastros desse período estão lá. Ligando a estação, os usuários passam a
escrever num banco que não tem esse período — e as duas produções divergem,
com registro de dinheiro nas duas.

⚠️ Isso é uma decisão de negócio, não de infraestrutura. O script não a toma
por você: ele EXIGE `-EuSeiDaDivergencia` e grava um MARCO antes de mexer em
qualquer coisa.

===========================================================================
O MARCO — o que torna a conciliação possível
===========================================================================
Antes de virar, ele conta as linhas das tabelas que importam e guarda em
`estacao/marcos/`. Sem isso, depois de uma semana de uso ninguém sabe dizer
quais linhas nasceram aqui e quais vieram de lá — e conciliar dinheiro no
olho é como a gente perde dinheiro.

.PARAMETER Para
`estacao` traz a produção para cá. `vm` devolve para a VM.

.PARAMETER EuSeiDaDivergencia
Obrigatório para `-Para estacao`. É o aceite explícito de que os dois bancos
vão divergir e alguém vai ter que juntá-los depois.

.EXAMPLE
.\virar-producao.ps1 -Para estacao -EuSeiDaDivergencia
.\virar-producao.ps1 -Para vm

.NOTES
Conferido em 23/08/2026. Repontar DNS leva segundos e é reversível pelo
mesmo caminho — foi medido com `quiz` e `api` antes de escrever isto.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('estacao', 'vm')][string]$Para,
    [switch]$EuSeiDaDivergencia,
    [string]$Cloudflared = 'C:\Program Files (x86)\cloudflared\cloudflared.exe',
    # ⚠️ Os dois túneis são DIFERENTES e têm configurações diferentes.
    #   `nerdquiz`    — serviço NerdQuizTunnel, config.yml, rotas de PRODUÇÃO
    #   `serverhomol` — roda DENTRO da VM; daqui só dá para apontar para ele
    [string]$TunelEstacao = '47a05dc3-c2d1-4801-bf63-d4cf4bc7a76b',
    [string]$TunelVM      = 'f0d7cd68-27da-4686-b826-4ce1d3a9243f',
    [switch]$SoConferir
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path $PSScriptRoot -Parent

# Os vinte nomes que o `config.yml` da estação sabe atender. Sair desta lista
# significa apontar um domínio para um túnel que não tem rota para ele — e o
# sintoma seria 404 do Cloudflare, que parece problema de DNS.
$DOMINIOS = @(
    'urupix.com.br', 'www.urupix.com.br', 'urupix.cursodetecnologia.dev.br',
    'sprinklegames.com.br', 'www.sprinklegames.com.br',
    'opuschat.cursodetecnologia.dev.br', 'cafe-api.cursodetecnologia.dev.br',
    'sigma-financeiro.cursodetecnologia.dev.br',
    'sigma-financeiro-sandbox.cursodetecnologia.dev.br',
    'sigma-midia.cursodetecnologia.dev.br',
    'sigma-midia-arquivos.cursodetecnologia.dev.br',
    'central-ia.cursodetecnologia.dev.br',
    'veltrixa.cursodetecnologia.dev.br',
    'ninjasystem.cursodetecnologia.dev.br',
    'ninjasystem-auth.cursodetecnologia.dev.br',
    'ninjasystem-admin.cursodetecnologia.dev.br',
    'sempre-mais-barato.cursodetecnologia.dev.br',
    'quiz.cursodetecnologia.dev.br', 'api.cursodetecnologia.dev.br'
)

# As tarefas que fazem o trabalho de fundo do urupix. Ficaram desativadas no
# corte de 21/08 — e é por isso que o app não sobe sozinho aqui.
$TAREFAS = @(
    'UrupixAutostart', 'UrupixWatchdog', 'UrupixDeliveryDrain',
    'UrupixLiveWatch', 'UrupixNoticeDispatch', 'UrupixNightlySync',
    'UrupixSaudeDaPilha'
)

# As contagens que viram o MARCO. Só o que responde "quanto dinheiro e quantas
# pessoas" — contar tudo daria um número grande e inútil.
$MARCADORES = @(
    @{ Cont = 'liveflow-db'; User = 'liveflow'; Base = 'liveflow'
       Consulta = 'select ''doacoes''||''='' || count(*) || '' ultima='' || coalesce(max("createdAt")::text,''-'') from "Donation"' }
    @{ Cont = 'liveflow-db'; User = 'liveflow'; Base = 'liveflow'
       Consulta = 'select ''usuarios''||''='' || count(*) from "User"' }
    @{ Cont = 'sigma-db'; User = 'sigma'; Base = 'sigma_financeiro'
       Consulta = 'select ''cobrancas''||''='' || count(*) || '' ultima='' || coalesce(max("createdAt")::text,''-'') from "Charge"' }
)

# ---------------------------------------------------------------------------
# ⚠️ PRECISA DE ADMINISTRADOR, e a recusa tem que vir ANTES de mexer em nada.
# ---------------------------------------------------------------------------
# 🐞 Sem esta guarda o script gravava o marco, comecava a virada e SO ENTAO
# tomava "Access is denied" no `Set-Service` -- deixando o ambiente no meio do
# caminho: marco gravado, tunel parado, dominios ainda apontando para a VM.
#
# Meio-caminho e o pior estado possivel numa virada de producao.
# ⚠️ E a guarda tem que estar DENTRO do script, nao na cabeca de quem roda.
#
# 🐞 Em 23/08/2026 eu contornei este script para reiniciar o tunel "rapidinho"
# com `Restart-Service` de um PowerShell comum. Ele NAO reiniciou -- e
# `Get-Service` respondeu `Running`, porque o servico ja estava rodando desde
# antes. Passei dez minutos procurando defeito na configuracao do Kong e do
# tunel, que estavam certas: o processo e que nunca releu o arquivo.
#
# Comando que falha sem dizer + consulta que responde o esperado por acidente
# = a combinacao mais cara de depurar.
function ExigirAdministrador {
    $eu = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $eu.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error @'
Recusando comecar: isto precisa de PowerShell como Administrador.

Ligar e desligar servico do Windows (o tunel) exige elevacao. Sem ela o
script pararia no meio, com o marco ja gravado e o ambiente pela metade.

Abra o PowerShell como Administrador e repita o comando.
'@
        exit 3
    }
}

function Diga($t) { Write-Host $t }

function MarcoDaVirada {
    $carimbo = Get-Date -Format 'yyyyMMdd-HHmmss'
    $pasta = Join-Path $PSScriptRoot 'marcos'
    if (-not (Test-Path $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }

    $linhas = @("# marco da virada — $carimbo — destino: $Para", '')
    foreach ($m in $MARCADORES) {
        try {
            # 🐞 A consulta vai pela ENTRADA, e nao como argumento.
            #
            # A primeira versao passava `-c $m.Consulta`, e o PowerShell 5.1
            # come as aspas duplas ao chamar executavel nativo. `from "User"`
            # chegava no Postgres como `from user` -- que e PALAVRA RESERVADA,
            # nao a tabela. O marco saiu com `usuarios=1` onde havia 14.
            #
            # ⚠️ Numero errado num marco de conciliacao e pior que marco
            # nenhum: ele tem cara de medida e ninguem confere duas vezes.
            $r = $m.Consulta | & docker exec -i $m.Cont psql -U $m.User -d $m.Base -tAf - 2>&1 |
                 Where-Object { $_ -and $_.ToString().Trim() } | Select-Object -First 1
            if ($r -match 'ERROR|FATAL') { throw $r }
            $linhas += "$($m.Cont)/$($m.Base): $($r -replace '\s+$','')"
        } catch {
            # ⚠️ Falha vira LINHA no marco, não silêncio: um marco incompleto
            # que se parece com um marco completo é pior que marco nenhum.
            $linhas += "$($m.Cont)/$($m.Base): NAO CONSEGUI LER — $($_.Exception.Message)"
        }
    }
    $arq = Join-Path $pasta "$carimbo-$Para.txt"
    $linhas | Set-Content -Path $arq -Encoding utf8
    Diga "  marco gravado em $arq"
    $linhas | ForEach-Object { Diga "    $_" }
}

function ApontarDominios($tunel) {
    $falhas = @()
    foreach ($d in $DOMINIOS) {
        try {
            $saida = & $Cloudflared tunnel route dns --overwrite-dns $tunel $d 2>&1 | Out-String
            if ($saida -match 'ERR|error') { $falhas += "$d :: $($saida.Trim())" }
        } catch { $falhas += "$d :: $($_.Exception.Message)" }
    }
    if ($falhas.Count) {
        Diga "  ⚠️ $($falhas.Count) domínio(s) NÃO foram repontados:"
        $falhas | ForEach-Object { Diga "    $_" }
    } else {
        Diga "  $($DOMINIOS.Count) domínios apontados para $tunel"
    }
}

function Conferir {
    # ⚠️ Confere o que o USUÁRIO vê, não o que o serviço diz de si mesmo.
    # "Running" já mentiu antes; 530 na porta 443 não mente.
    # 🐞 `curl.exe`, e NAO `Invoke-WebRequest`.
    #
    # `-SkipHttpErrorCheck` so existe do PowerShell 6 em diante. No 5.1 desta
    # maquina, qualquer resposta que nao fosse 2xx virava excecao, caia no
    # `catch` e era contada como ZERO -- e a primeira execucao desta virada
    # relatou "19 de 19 ainda NAO atendem" com a producao INTEIRA no ar.
    #
    # ⚠️ Guarda que grita errado e pior que guarda nenhuma: ela teria me feito
    # desfazer uma virada que tinha dado certo.
    $ruins = @()
    foreach ($d in $DOMINIOS) {
        $c = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 15 "https://$d/" 2>$null)
        if (-not $c) { $c = 0 } else { $c = [int]$c }
        # 530 = túnel sem destino. 502 = túnel entrega e ninguém atende.
        if ($c -eq 530 -or $c -eq 0 -or $c -eq 502) { $ruins += "$d -> $c" }
    }
    if ($ruins.Count) {
        Diga ''
        Diga "  ⚠️ $($ruins.Count) de $($DOMINIOS.Count) ainda NÃO atendem:"
        $ruins | ForEach-Object { Diga "    $_" }
    } else {
        Diga ''
        Diga "  ✅ os $($DOMINIOS.Count) domínios atendem."
    }
    return $ruins.Count
}

# ---------------------------------------------------------------- conferir só
if ($SoConferir) {
    Diga 'Conferindo o estado atual, sem mexer em nada.'
    exit (Conferir)
}

# ---------------------------------------------------------------- para a VM
if ($Para -eq 'vm') {
    ExigirAdministrador
    Diga 'Devolvendo a produção para a VM `serverhomol`.'
    Diga ''
    MarcoDaVirada
    Diga ''
    Diga '== Parando o que atende aqui'
    foreach ($t in $TAREFAS) {
        Disable-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue | Out-Null
    }
    Diga "  $($TAREFAS.Count) tarefa(s) do urupix desativada(s)"
    Stop-Service -Name 'NerdQuizTunnel' -ErrorAction SilentlyContinue
    Set-Service -Name 'NerdQuizTunnel' -StartupType Disabled -ErrorAction SilentlyContinue
    Diga '  túnel da estação parado e desativado'
    Diga ''
    Diga '== Apontando os domínios para a VM'
    ApontarDominios $TunelVM
    Diga ''
    Diga '⚠️ A VM precisa estar LIGADA e com o `cloudflared` de pé. Sem isso os'
    Diga '   domínios voltam a devolver 530 — agora por falta de destino lá.'
    exit (Conferir)
}

# ---------------------------------------------------------------- para cá
if (-not $EuSeiDaDivergencia) {
    Write-Error @'
Recusando virar sem o aceite explícito.

Os dois lados têm banco próprio, e virar NÃO copia dado. Desde 21/08 os
domínios atenderam pela VM: doações e cadastros desse período estão LÁ.
Ligando aqui, os usuários escrevem num banco que não os tem, e as duas
produções divergem — com registro de dinheiro nas duas.

Sabendo disso e aceitando conciliar depois, repita com:

    .\virar-producao.ps1 -Para estacao -EuSeiDaDivergencia
'@
    exit 2
}

ExigirAdministrador
Diga 'Trazendo a produção para ESTA estação.'
Diga ''
MarcoDaVirada

Diga ''
Diga '== Túnel da estação'
Set-Service -Name 'NerdQuizTunnel' -StartupType Automatic
Start-Service -Name 'NerdQuizTunnel'
# O túnel leva alguns segundos para registrar as conexões nos servidores de
# borda. Apontar o DNS antes disso deixaria uma janela de 530.
Start-Sleep -Seconds 8
$svc = Get-Service -Name 'NerdQuizTunnel'
Diga "  NerdQuizTunnel: $($svc.Status)"

Diga ''
Diga '== Tarefas de fundo do urupix'
foreach ($t in $TAREFAS) {
    Enable-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue | Out-Null
}
# ⚠️ O `Autostart` é quem SOBE o app. Habilitar não executa: sem este disparo
# o urupix só voltaria no próximo gatilho da tarefa, e até lá Kong responde
# 502 — que parece o app quebrado, e é só o app ausente.
Start-ScheduledTask -TaskName 'UrupixAutostart' -ErrorAction SilentlyContinue
Diga "  $($TAREFAS.Count) tarefa(s) reativada(s); UrupixAutostart disparado"

Diga ''
Diga '== Apontando os domínios para a estação'
ApontarDominios $TunelEstacao

Diga ''
Diga '== Esperando o app do urupix responder na 3100'
$ok = $false
foreach ($i in 1..45) {
    $c = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 5 'http://127.0.0.1:3100/' 2>$null)
    if ($c -and [int]$c -lt 500 -and [int]$c -gt 0) { $ok = $true; break }
    Start-Sleep -Seconds 4
}
Diga $(if ($ok) { '  urupix respondendo' } else { '  ⚠️ urupix NÃO respondeu em 2 min — ver C:\Users\samue\.urupix\' })

exit (Conferir)

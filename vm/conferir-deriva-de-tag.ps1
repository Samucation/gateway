<#
.SYNOPSIS
Compara a tag que cada overlay `prd` DECLARA com a que o cluster ESTA RODANDO.

.DESCRIPTION
---------------------------------------------------------------------------
🐞 POR QUE ISTO EXISTE
---------------------------------------------------------------------------
Em 22/08/2026 dois projetos estavam com o Git discordando do cluster:

    live-flow    declarava 20260820-0655   rodava 477b1d978a42
    sigma-midia  declarava 20260819-2021   rodava 3066cafeff45

⚠️ A esteira NAO percebe, e nao e defeito dela: ela reescreve a linha da tag
no espaco de trabalho descartavel antes de aplicar. O valor guardado no
repositorio nunca e lido por ela.

Quem le esse valor e a PESSOA que roda `kubectl apply -k k8s/overlays/prd` a
mao. E isso acontece exatamente na pior hora -- numa emergencia, com pressa.
O resultado e producao voltando em silencio para uma versao anterior, com o
repositorio parecendo certo o tempo todo.

⚠️ No caso do sigma-midia seria pior que um retorno de versao: as duas tags
declaradas eram as publicadas SEM `--provenance=false`, que nao sao baixaveis.
O apply nao teria voltado a versao -- teria derrubado producao em
`ImagePullBackOff`.

.NOTES
Roda daqui, por SSH. Nao altera nada; so compara e conta.
#>
param(
    # ⚠️ VAZIO por padrao: o endereco e DESCOBERTO, nao chutado.
    #
    # 🐞 Estava fixo em `192.168.15.55`. Em 22/08/2026 a VM trocou para `.56`
    # sozinha, e este script passou a nao conseguir falar com o cluster --
    # reportando as tags como "NAO ESTA RODANDO", que e exatamente o alarme que
    # ele existe para dar. Guarda que grita errado ensina a ignorar o alarme.
    #
    # `achar-vm.ps1` varre a faixa e CONFERE O NOME da maquina antes de devolver
    # o endereco, entao ele nao entrega o aparelho errado.
    [string]$Vm      = '',
    [string]$Usuario = 'usuario',
    [string]$Chave   = "$env:USERPROFILE\.ssh\id_hmg_veltrixa"
)

# ⚠️ `Continue`, e NAO `Stop`: no PowerShell 5.1 a saida de erro de um programa
# externo vira ErrorRecord e mataria o script em respostas que sao normais.
$ErrorActionPreference = 'Continue'

$raiz = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

if (-not $Vm) {
    $Vm = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'achar-vm.ps1') |
           Select-Object -Last 1).Trim()
    if (-not $Vm) { throw 'nao achei a VM na rede -- veja vm/IP-OSCILANDO.md' }
    Write-Host "  VM encontrada em $Vm" -ForegroundColor DarkGray
}

$ssh  = @('-i', $Chave, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', "$Usuario@$Vm")

# Namespace de cada repositorio. Nem sempre e o nome da pasta -- `live-flow`
# roda em `urupix`, `cafe-mobile-erp` em `plataforma`, `system-api` em
# `veltrixa`.
$mapa = [ordered]@{
    'live-flow'            = 'urupix'
    'sprinklegames-portal' = 'sprinklegames'
    'sigma-financeiro'     = 'sigma-financeiro'
    'sigma-midia'          = 'sigma-midia'
    'opuschat'             = 'opuschat'
    'cafe-mobile-erp'      = 'plataforma'
    'system-api'           = 'veltrixa'
    'central-ia'           = 'central-ia'
}

Write-Host ''
Write-Host 'Comparando o que o Git DECLARA com o que o cluster RODA...' -ForegroundColor Cyan
Write-Host ''

$problemas = 0

foreach ($repo in $mapa.Keys) {
    $ns      = $mapa[$repo]
    $overlay = Join-Path $raiz "$repo\k8s\overlays\prd\kustomization.yaml"

    if (-not (Test-Path $overlay)) {
        Write-Host ("  {0,-22} sem overlay de prd -- pulado" -f $repo) -ForegroundColor DarkGray
        continue
    }

    # --- o que o Git declara -----------------------------------------------
    # Casa `- name: <imagem>` seguido de `newTag: "<tag>"`.
    $texto     = Get-Content $overlay -Raw
    $declarado = @{}
    $casos = [regex]::Matches($texto, '(?m)^\s*-\s*name:\s*localhost:32000/([\w.-]+)\s*\r?\n\s*newTag:\s*"?([\w.-]+)"?')
    foreach ($c in $casos) { $declarado[$c.Groups[1].Value] = $c.Groups[2].Value }

    if ($declarado.Count -eq 0) {
        Write-Host ("  {0,-22} nenhuma imagem declarada -- pulado" -f $repo) -ForegroundColor DarkGray
        continue
    }

    # --- o que o cluster roda ----------------------------------------------
    # ⚠️ `{..image}`, e nao um `{range}` com quebra de linha dentro.
    #
    # 🐞 A primeira versao usava
    #   -o jsonpath='{range .items[*]}...{"\n"}{end}'
    # e devolvia VAZIO -- o que a guarda leu como "nenhuma imagem esta
    # rodando" e reportou como 13 divergencias, todas falsas.
    #
    # A quebra de linha literal dentro do jsonpath nao sobrevive ao caminho
    # PowerShell -> ssh -> shell remoto: ela vira quebra de linha DE VERDADE no
    # meio do argumento, e o comando chega partido em dois.
    #
    # ⚠️ Guarda que grita errado e pior que guarda nenhuma: ensina a ignorar o
    # alarme. `{..image}` devolve tudo separado por espaco e nao tem escape
    # nenhum para se perder no caminho.
    $consulta = "sudo microk8s kubectl get deploy,statefulset -n $ns -o jsonpath='{..image}' 2>/dev/null"
    $saida = (& ssh @ssh $consulta) -join ' '

    $rodando = @{}
    foreach ($linha in $saida -split "`n") {
        foreach ($img in $linha -split '\s+') {
            if ($img -match '^localhost:32000/([\w.-]+):([\w.-]+)$') {
                $rodando[$Matches[1]] = $Matches[2]
            }
        }
    }

    foreach ($img in $declarado.Keys) {
        $g = $declarado[$img]
        $c = $rodando[$img]

        if (-not $c) {
            Write-Host ("  {0,-22} {1,-24} declara {2} -- NAO ESTA RODANDO" -f $repo, $img, $g) -ForegroundColor Yellow
            $problemas++
        }
        elseif ($g -ne $c) {
            Write-Host ("  {0,-22} {1,-24} DERIVA: git={2}  cluster={3}" -f $repo, $img, $g, $c) -ForegroundColor Red
            $problemas++
        }
        else {
            Write-Host ("  {0,-22} {1,-24} ok ({2})" -f $repo, $img, $g) -ForegroundColor DarkGray
        }
    }
}

Write-Host ''
if ($problemas -gt 0) {
    Write-Host "$problemas divergencia(s)." -ForegroundColor Red
    Write-Host 'Corrija o OVERLAY para a tag que esta no ar -- e nao o contrario.' -ForegroundColor Yellow
    Write-Host 'Aplicar o overlay como esta faria producao voltar de versao em silencio.'
    exit 1
}

Write-Host 'Git e cluster concordam em todos os projetos.' -ForegroundColor Green
exit 0

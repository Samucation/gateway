<#
.SYNOPSIS
Monta (ou remonta) o cluster de HOMOLOGAÇÃO desta estação, do zero.

.DESCRIPTION
⚠️ ESTE SCRIPT EXISTE PORQUE O CLUSTER PRECISOU SER RECRIADO TRÊS VEZES em
21/08/2026 — porta da API aleatória, certificado sem o IP da rede, e o
`--disable=servicelb`. A cada vez eu refiz namespaces, segredos, RBAC e classe
de armazenamento à mão, e errei a ordem uma vez.

Um cluster que se remonta com um comando é a diferença entre "recriar é caro,
melhor remendar" e "recriar é barato, então conserta direito".

⚠️ O que ele NÃO faz: apagar dados. Se o cluster já existe, ele para e avisa —
use `-Recriar` para descartar de propósito.

.EXAMPLE
.\estacao\montar-hmg.ps1
.\estacao\montar-hmg.ps1 -Recriar
#>
[CmdletBinding()]
param(
    [switch]$Recriar,
    [string]$Contexto = 'k3d-hmg'
)

# 🐞 `Continue`, e não `Stop`: no PowerShell 5.1 a saída de erro de um programa
# externo vira ErrorRecord, e um `kubectl get` de coisa que ainda não existe
# mataria o script. As falhas que importam são conferidas por `$LASTEXITCODE`.
$ErrorActionPreference = 'Continue'

$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$k3d  = "$env:USERPROFILE\bin\k3d.exe"
# ⚠️ NOVE, e não oito. Esta lista tem de casar com as OUTRAS DUAS que já
# assumem nove: o `resourceNames` de `jenkins-rbac-hmg.yaml` e os `Aplicar` de
# `segredos-hmg.ps1`.
#
# 🐞 Ficou com oito até 28/08/2026, sem `sigma-payments`. O efeito só aparecia
# no ÚLTIMO passo de uma remontagem completa: os oito primeiros segredos eram
# aplicados, o nono morria em
#
#     falhou ao aplicar sigma-payments-secrets em sigma-payments
#
# e o script saía com 1 — depois de já ter montado 95% do cluster. Quem lesse a
# mensagem procuraria defeito no SEGREDO; a causa era o namespace que nunca foi
# criado, dois passos antes.
#
# ⚠️ O `jenkins-rbac-hmg.yaml` já traz o comentário de que este projeto foi "o
# nono, esquecido" numa lista anterior. É a MESMA omissão, repetida noutro
# arquivo — sinal de que a lista precisa de um dono só. Enquanto não tiver,
# mudou aqui, confira os outros dois.
$NS   = @('urupix','sprinklegames','opuschat','plataforma','central-ia','veltrixa','sigma-financeiro','sigma-midia','sigma-payments')

function Passo($t) { Write-Host "==> $t" -ForegroundColor Cyan }

# ---- 1. o cluster ---------------------------------------------------------
& $k3d cluster list hmg *> $null
if ($LASTEXITCODE -eq 0) {
    if (-not $Recriar) {
        Write-Host 'O cluster `hmg` ja existe. Use -Recriar para descartar e montar de novo.' -ForegroundColor Yellow
        exit 0
    }
    Passo 'descartando o cluster antigo'
    & $k3d cluster delete hmg *> $null
}

Passo 'criando o cluster'
& $k3d cluster create --config (Join-Path $raiz 'k3d-hmg.yaml')
if ($LASTEXITCODE -ne 0) { throw 'falhou ao criar o cluster' }

# ---- 2. esperar o Traefik ------------------------------------------------
#
# ⚠️ O k3s instala o Traefik por Helm DEPOIS que a API responde. Aplicar Ingress
# antes disso funciona (o objeto é aceito), mas nada roteia — e o sintoma é
# "tudo verde e nada responde".
Passo 'esperando o Traefik'
$ok = $false
foreach ($i in 1..30) {
    $r = & kubectl --context $Contexto get pods -n kube-system -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.phase}' 2>$null
    if ("$r" -eq 'Running') { $ok = $true; break }
    Start-Sleep -Seconds 10
}
if (-not $ok) { throw 'o Traefik nao subiu' }

# ---- 3. a classe de armazenamento com o nome que os manifestos pedem -----
Passo 'classe de armazenamento'
& kubectl --context $Contexto apply -f (Join-Path $raiz 'storageclass-hmg.yaml')

# ---- 4. namespaces --------------------------------------------------------
Passo 'namespaces'
foreach ($n in $NS) { & kubectl --context $Contexto create namespace $n *> $null }

# ---- 5. RBAC do Jenkins ---------------------------------------------------
Passo 'permissoes do Jenkins'
& kubectl --context $Contexto apply -f (Join-Path $raiz 'jenkins-rbac-hmg.yaml')
& kubectl --context $Contexto apply -f (Join-Path $raiz 'jenkins-sa-hmg.yaml')
foreach ($n in $NS) {
    & kubectl --context $Contexto create rolebinding jenkins-admin `
        --clusterrole=admin --serviceaccount=default:jenkins -n $n *> $null
}

# ---- 6. segredos ----------------------------------------------------------
Passo 'segredos de homologacao'
& (Join-Path $raiz 'segredos-hmg.ps1')

Write-Host ''
Write-Host 'Cluster de homologacao pronto.' -ForegroundColor Green
Write-Host '⚠️ Falta levar o kubeconfig novo para o Jenkins da VM:' -ForegroundColor Yellow
Write-Host '   .\estacao\kubeconfig-para-jenkins.ps1'

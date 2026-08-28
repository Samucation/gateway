<#
.SYNOPSIS
Gera o kubeconfig do cluster de HOMOLOGAÇÃO e o instala no Jenkins.

.DESCRIPTION
⚠️ RODAR SEMPRE QUE O CLUSTER FOR RECRIADO. O token da ServiceAccount e a CA
mudam junto com o cluster; sem isto o Jenkins segue com credencial de um cluster
que não existe mais, e o erro aparece como "Unauthorized" no meio do deploy —
depois de a esteira já ter construído, testado e publicado a imagem.

===========================================================================
⚠️ MUDOU EM 28/08/2026 — O JENKINS NÃO ESTÁ MAIS NA VM
===========================================================================
A versão anterior empurrava o arquivo por SSH para a VM `serverhomol`. A VM foi
desligada em 24/08 e o Jenkins passou a rodar como serviço do systemd na distro
WSL2 `prd`, nesta mesma estação.

O script continuava chamando `vm/achar-vm.ps1` e morreria em "nao achei a
serverhomol" — ou, pior, acharia uma máquina qualquer no endereço que a VM
tinha e escreveria lá.

🐞 E ninguém teria percebido antes de precisar: ele só é chamado quando o
cluster é recriado, que aconteceu hoje pela primeira vez desde a virada.

===========================================================================
O CAMINHO, E POR QUE ELE É PELO IP DA LAN
===========================================================================
O Jenkins está na distro `prd`; o cluster de homologação está no Docker Desktop.
As duas distros do WSL **não se enxergam** — medido: `ping` de um contêiner para
a distro perde 100% dos pacotes. Elas só se encontram através de porta publicada
no host Windows.

Por isso o destino é `https://192.168.15.9:6550` (o IP da estação na LAN), e não
`localhost`. O `k3d-hmg.yaml` assina o certificado da API para esse endereço
justamente por causa disto — sem o `--tls-san`, daria erro de TLS, que parece
problema de credencial e é de certificado.

.EXAMPLE
.\estacao\kubeconfig-para-jenkins.ps1
#>
[CmdletBinding()]
param(
    [string]$Contexto = 'k3d-hmg',
    [string]$Estacao  = '192.168.15.9',
    [string]$Porta    = '6550',
    [string]$Distro   = 'prd'
)

# 🐞 `Continue`, e nao `Stop`: saida de erro de executavel externo vira
# ErrorRecord no PowerShell 5.1. Mesma armadilha ja documentada em
# `segredos-hmg.ps1` e `montar-hmg.ps1`.
$ErrorActionPreference = 'Continue'

function Diga($t) { Write-Host "    $t" }

$token = & kubectl --context $Contexto get secret jenkins-token -n default -o jsonpath='{.data.token}' 2>$null
$ca    = & kubectl --context $Contexto get secret jenkins-token -n default -o jsonpath='{.data.ca\.crt}' 2>$null
if (-not $token) {
    Write-Host 'nao achei o token -- o Secret jenkins-token existe?' -ForegroundColor Red
    Diga "kubectl --context $Contexto get secret jenkins-token -n default"
    Diga 'se faltar, rode:  .\estacao\montar-hmg.ps1'
    exit 1
}
$token = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("$token"))

# ⚠️ `-join "`n"`, e nao here-string solta: o PowerShell no Windows termina
# linha com CRLF, e o `\r` no meio de um valor YAML entra NO VALOR. Um token com
# `\r` no fim e recusado com "Unauthorized" -- que manda procurar em permissao,
# nao em fim de linha. O `tr -d` do lado de la e a segunda tranca.
$kc = @(
    'apiVersion: v1'
    'kind: Config'
    'clusters:'
    '  - name: hmg'
    '    cluster:'
    "      server: https://${Estacao}:${Porta}"
    "      certificate-authority-data: $ca"
    'users:'
    '  - name: jenkins'
    '    user:'
    "      token: $token"
    'contexts:'
    '  - name: hmg'
    '    context: { cluster: hmg, user: jenkins }'
    'current-context: hmg'
) -join "`n"

$destino = '/var/lib/jenkins/.kube/config-hmg'

# ⚠️ Por STDIN: como argumento, o token apareceria em `ps` para qualquer usuario
# da maquina e ficaria no historico do shell.
$kc | & wsl.exe -d $Distro -u root -- bash -c "mkdir -p /var/lib/jenkins/.kube && tr -d '\r' > $destino && chown jenkins:jenkins $destino && chmod 600 $destino"
if ($LASTEXITCODE -ne 0) {
    Write-Host 'falhou ao escrever o kubeconfig na distro' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# ⚠️ A PROVA E O JENKINS FALANDO COM O CLUSTER, e nao o arquivo existir.
#
# Arquivo escrito nao e credencial valida: foi exatamente esse o modo de falha
# que este script existe para evitar. Entao conferimos DE DENTRO, com o usuario
# `jenkins`, usando o arquivo que acabou de ser gravado.
#
# 🐞 A PROVA TEM DE USAR UM VERBO QUE O RBAC PERMITE.
#
# A primeira versao pedia `get nodes` -- e o `jenkins-rbac-hmg.yaml` NEGA isso
# de proposito: aquele token so alcanca os nove namespaces, nominalmente, e nao
# o escopo de cluster. O resultado era
#
#     Error from server (Forbidden): nodes is forbidden
#
# com o kubeconfig PERFEITO, e o script reprovando a propria instalacao.
#
# ⚠️ E `Forbidden` ja e, em si, prova de que a AUTENTICACAO funcionou: o
# servidor identificou `system:serviceaccount:default:jenkins`. Token velho ou
# CA errada dariam `Unauthorized`, que e outra palavra. Distinguir as duas
# poupa procurar credencial quando o problema e permissao -- e vice-versa.
#
# Aqui pedimos o que a esteira realmente faz: enxergar um namespace de deploy.
$prova = & wsl.exe -d $Distro -u root -- su -s /bin/bash jenkins -c "kubectl --kubeconfig $destino get deploy -n urupix 2>&1"
$prova = ("$prova" -replace "`0", '').Trim()
Diga "o Jenkins consultando o namespace urupix: $prova"

# Namespace vazio devolve "No resources found", que e resposta VALIDA -- o
# cluster acabou de ser remontado e as esteiras ainda nao implantaram nada.
if ($prova -notmatch 'Unauthorized|Forbidden|refused|no such host|certificate') {
    Write-Host '==> kubeconfig instalado e PROVADO (Jenkins na distro prd)' -ForegroundColor Green
    exit 0
}

Write-Host "o Jenkins NAO conseguiu falar com o cluster: $prova" -ForegroundColor Red
exit 1

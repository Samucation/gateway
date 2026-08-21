<#
.SYNOPSIS
Gera o kubeconfig do cluster de homologacao e o instala no Jenkins da VM.

.DESCRIPTION
⚠️ RODAR SEMPRE QUE O CLUSTER FOR RECRIADO. O token da ServiceAccount e a CA
mudam junto com o cluster; sem isto o Jenkins segue com credencial de um cluster
que nao existe mais, e o erro aparece como "Unauthorized" no meio do deploy.
#>
[CmdletBinding()]
param(
    [string]$Contexto = 'k3d-hmg',
    [string]$Estacao  = '192.168.15.9',
    [string]$Porta    = '6550',
    [string]$Chave    = "$env:USERPROFILE\.ssh\id_hmg_veltrixa",
    [string]$Usuario  = 'usuario',
    [string]$Vm       = ''
)
$ErrorActionPreference = 'Continue'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Vm) { $Vm = & (Join-Path $raiz '..\vm\achar-vm.ps1') }
if (-not $Vm) { throw 'nao achei a serverhomol' }

$token = & kubectl --context $Contexto get secret jenkins-token -n default -o jsonpath='{.data.token}' 2>$null
$ca    = & kubectl --context $Contexto get secret jenkins-token -n default -o jsonpath='{.data.ca\.crt}' 2>$null
if (-not $token) { throw 'nao achei o token -- o Secret jenkins-token existe?' }
$token = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("$token"))

$kc = @"
apiVersion: v1
kind: Config
clusters:
  - name: hmg
    cluster:
      server: https://${Estacao}:${Porta}
      certificate-authority-data: $ca
users:
  - name: jenkins
    user:
      token: $token
contexts:
  - name: hmg
    context: { cluster: hmg, user: jenkins }
current-context: hmg
"@

# ⚠️ Por STDIN: como argumento, o token apareceria em `ps` para qualquer usuario
# da maquina e ficaria no historico do shell.
$kc | & ssh -i $Chave -o BatchMode=yes -o StrictHostKeyChecking=no "$Usuario@$Vm" `
  "cat > /tmp/kc && sudo mv /tmp/kc /var/lib/jenkins/.kube/config-hmg && sudo chown jenkins:jenkins /var/lib/jenkins/.kube/config-hmg && sudo chmod 600 /var/lib/jenkins/.kube/config-hmg"
if ($LASTEXITCODE -ne 0) { throw 'falhou ao instalar o kubeconfig na VM' }
Write-Host "==> kubeconfig instalado no Jenkins ($Vm)" -ForegroundColor Green

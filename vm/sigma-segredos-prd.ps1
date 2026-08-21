<#
.SYNOPSIS
Leva os segredos de PRODUÇÃO do sigma-financeiro para o cluster.

.DESCRIPTION
⚠️ ESTE SCRIPT MORA NO `gateway`, E NÃO NO REPO DO SIGMA-FINANCEIRO.

O repositório do sigma-financeiro é SÓ LEITURA por regra do dono — a exceção
combinada cobre apenas o diretório `k8s/`. Ferramenta de infraestrutura fica
aqui.

⚠️ `TOKEN_ENCRYPTION_KEY` É O PONTO INTEIRO DESTE SCRIPT.

Ela cifra as credenciais dos adquirentes guardadas no banco. O cluster tinha uma
chave PRÓPRIA, gerada para homologação — e isso estava certo enquanto ele era
homologação: chave compartilhada faria uma credencial cifrada em teste valer em
produção.

Ao trazer o BANCO de produção, a conta inverte. Medido em 21/08/2026, pela
impressão SHA-256 dos dois lados:

    produção: 520d216206de054f
    cluster : 0e1627b8c2fe05d2

Com a chave errada a decifragem falha, e o código trata como "não configurado":
o serviço sobe, responde 200, e as credenciais somem sem uma linha de erro.

⚠️ Nenhum valor é impresso nem gravado em arquivo. O YAML vai por STDIN — como
argumento de linha de comando ele apareceria em `ps` para qualquer usuário da
máquina e ficaria no histórico do shell.

.EXAMPLE
.\vm\sigma-segredos-prd.ps1 -Conferir
.\vm\sigma-segredos-prd.ps1
#>
[CmdletBinding()]
param(
    [string]$Env       = '',
    [string]$Namespace = 'sigma-financeiro',
    [string]$Nome      = 'sigma-financeiro-secrets',
    [string]$Vm        = '',
    [string]$Chave     = "$env:USERPROFILE\.ssh\id_hmg_veltrixa",
    [string]$Usuario   = 'usuario',
    [switch]$Conferir
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Env) { $Env = Join-Path $raiz '..\..\sigma-financeiro\.env' }
if (-not $Vm)  { $Vm  = & (Join-Path $raiz 'achar-vm.ps1') }
if (-not $Vm)  { throw 'nao achei a serverhomol na rede' }
Write-Host "==> serverhomol em $Vm" -ForegroundColor Cyan

if (-not (Test-Path $Env)) { throw "nao achei o .env em $Env" }

# ---- ler o .env -----------------------------------------------------------
$vals = [ordered]@{}
foreach ($l in Get-Content $Env) {
    if ($l -match '^\s*#') { continue }
    if ($l -notmatch '^\s*([A-Z_][A-Z0-9_]*)\s*=(.*)$') { continue }
    $k = $Matches[1]; $v = $Matches[2].Trim()
    if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) {
        $v = $v.Substring(1, $v.Length - 2)
    }
    $vals[$k] = $v
}

# ---- o que o ConfigMap manda ----------------------------------------------
# Ambiente, porta, URL pública e países saem do overlay — não do .env da
# estação, que traz `localhost` no banco e a porta local.
foreach ($k in @('SIGMA_AMBIENTE','PORT','SIGMA_PUBLIC_URL','SIGMA_PAISES_PERMITIDOS')) {
    $vals.Remove($k) | Out-Null
}

# ---- o banco é DO CLUSTER --------------------------------------------------
#
# ⚠️ O `.env` aponta para `localhost:5434` — dentro do contêiner isso é o
# PRÓPRIO contêiner. A senha vem do Secret que já existe no cluster, que é a
# única fonte que não fica desatualizada em dois lugares.
$pw = & ssh -i $Chave -o BatchMode=yes -o StrictHostKeyChecking=no "$Usuario@$Vm" `
    'sudo microk8s kubectl exec -n sigma-financeiro sigma-db-0 -- printenv POSTGRES_PASSWORD' 2>$null
$pw = ("$pw").Trim()
if (-not $pw) { throw 'nao consegui ler POSTGRES_PASSWORD do Pod do banco -- abortando' }

$vals['POSTGRES_PASSWORD']     = $pw
$vals['DATABASE_URL']          = "postgresql://sigma:$pw@sigma-db:5432/sigma_financeiro?schema=public"
$vals['DATABASE_URL_PRODUCAO'] = $vals['DATABASE_URL']
$vals['DATABASE_URL_SANDBOX']  = "postgresql://sigma:$pw@sigma-db-sandbox:5432/sigma_financeiro_sandbox?schema=public"

Write-Host ("==> {0} chaves para o Secret" -f $vals.Count)

if ($Conferir) {
    $q = 'sudo microk8s kubectl get secret ' + $Nome + ' -n ' + $Namespace + ' -o jsonpath={.data}'
    $bruto = & ssh -i $Chave -o BatchMode=yes -o StrictHostKeyChecking=no "$Usuario@$Vm" $q 2>$null
    $tem = @()
    foreach ($m in [regex]::Matches([string]$bruto, '"([A-Z_][A-Z0-9_]*)":')) { $tem += $m.Groups[1].Value }
    $faltam = @($vals.Keys | Where-Object { $_ -notin $tem })
    Write-Host ("    no cluster: {0} | faltam: {1}" -f $tem.Count, $faltam.Count)
    if ($faltam.Count) { Write-Host ('    -> ' + ($faltam -join ' ')) -ForegroundColor Yellow }
    exit 0
}

# ⚠️ Valor VAZIO precisa virar `""`, e não ficar em branco depois dos dois
# pontos.
#
# 🐞 `GOOGLE_CLIENT_ID` e `GOOGLE_CLIENT_SECRET` estão vazios no `.env` de
# produção (o login com Google do admin nunca foi configurado). O script
# emitia `  GOOGLE_CLIENT_ID: ` — que o YAML lê como NULO, e o kubectl
# simplesmente NÃO CRIA a chave.
#
# O Deployment referencia as duas por `secretKeyRef` sem `optional`, então o Pod
# morria em `CreateContainerConfigError` com
#
#     couldn't find key GOOGLE_CLIENT_ID in Secret ...
#
# ⚠️ E o erro fala de contêiner, não de segredo vazio — manda procurar no lugar
# errado. Chave presente e vazia é diferente de chave ausente.
$linhas = foreach ($k in $vals.Keys) {
    $b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$vals[$k]))
    if ($b) { '  {0}: {1}' -f $k, $b } else { '  {0}: ""' -f $k }
}
$yaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: $Nome
  namespace: $Namespace
type: Opaque
data:
$($linhas -join "`n")
"@

$yaml | & ssh -i $Chave -o BatchMode=yes -o StrictHostKeyChecking=no "$Usuario@$Vm" `
    "cat > /tmp/sigma-secrets.yaml && sudo microk8s kubectl apply -f /tmp/sigma-secrets.yaml && rm -f /tmp/sigma-secrets.yaml"

if ($LASTEXITCODE -ne 0) { throw 'falhou ao aplicar o Secret' }
Write-Host '==> Secret aplicado' -ForegroundColor Green

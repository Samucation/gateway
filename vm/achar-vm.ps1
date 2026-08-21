<#
.SYNOPSIS
Descobre o IP da `serverhomol` na rede local.

.DESCRIPTION
⚠️ POR QUE ISTO EXISTE

A VM está em DHCP e o roteador vem alternando o endereço dela. Observado em
21/08/2026, em menos de duas horas e SEM reiniciar:

    192.168.15.55  ->  192.168.15.56  ->  192.168.15.55

E depois de um reinício, foi para .56 de novo. Todo script que guardava o IP
fixo passou a falhar com "Connection timed out" — um erro que parece máquina
fora do ar, e não endereço trocado. Já custou tempo procurando defeito onde não
havia.

O conserto DEFINITIVO é reserva de DHCP no roteador (endereço fixo por MAC).
Enquanto ela não existe, isto evita que a troca quebre os scripts.

⚠️ O nome NÃO resolve nesta rede — nem por DNS, nem por mDNS, nem por NetBIOS.
Foi conferido. Por isso a busca é por varredura, e não por `Resolve-DnsName`.

⚠️ Confere o HOSTNAME depois de conectar. Achar "alguém com a porta 22 aberta"
não basta: qualquer outra máquina da rede responderia, e o script seguinte
mandaria comandos com `sudo` para a máquina errada.

.EXAMPLE
$vm = & .\achar-vm.ps1
ssh -i $env:USERPROFILE\.ssh\id_hmg_veltrixa usuario@$vm
#>
[CmdletBinding()]
param(
    [string]$Prefixo = '192.168.15',
    [string]$Chave   = "$env:USERPROFILE\.ssh\id_hmg_veltrixa",
    [string]$Usuario = 'usuario',
    [string]$Esperado = 'serverhomol',
    # tentados primeiro, na ordem: são os endereços que ela já usou
    [int[]]$Provaveis = @(56, 55, 54, 57)
)

$ErrorActionPreference = 'Stop'

function Test-Vm {
    param([string]$Ip)

    # porta 22 antes do SSH: sem isto cada host morto custaria o tempo cheio de
    # espera do cliente SSH, e a varredura levaria minutos.
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        if (-not $tcp.ConnectAsync($Ip, 22).Wait(600)) { return $false }
    } catch { return $false } finally { $tcp.Dispose() }

    $nome = & ssh -i $Chave -o BatchMode=yes -o StrictHostKeyChecking=no `
                 -o ConnectTimeout=5 "$Usuario@$Ip" hostname 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }

    return ("$nome".Trim() -eq $Esperado)
}

foreach ($n in $Provaveis) {
    $ip = "$Prefixo.$n"
    Write-Verbose "tentando $ip"
    if (Test-Vm -Ip $ip) { Write-Output $ip; exit 0 }
}

# não estava onde costuma estar: varre o resto da faixa
Write-Verbose "não achei nos prováveis; varrendo $Prefixo.0/24"
foreach ($n in 2..254) {
    if ($Provaveis -contains $n) { continue }
    $ip = "$Prefixo.$n"
    if (Test-Vm -Ip $ip) { Write-Output $ip; exit 0 }
}

Write-Error @"
Não achei a $Esperado em $Prefixo.0/24.

Confira, nesta ordem:
  1. a VM está ligada?
  2. ela pegou endereço em outra faixa? (no console dela: hostname -I)
  3. a chave $Chave ainda é aceita?
"@
exit 1

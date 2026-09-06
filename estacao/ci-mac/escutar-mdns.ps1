<#
.SYNOPSIS
Escuta o tráfego mDNS da rede e mostra quem se anuncia.

.DESCRIPTION
🐞 POR QUE ESCUTAR, E NAO PERGUNTAR

A versao anterior (`achar-o-mac.ps1`) mandava consultas mDNS e nao recebeu
NADA -- nem do roteador. Isso nao significa "a rede esta vazia": significa
que a resposta de volta, em UDP para uma porta efemera, e' descartada pelo
Firewall do Windows antes de chegar ao script.

⚠️ Conclusao errada e' facil aqui: "nao respondeu" vira "nao existe". E' a
mesma armadilha de [[regra-nao-medido-nao-e-zero]].

Escutar e' diferente: entra-se no grupo multicast 224.0.0.251 e recebe-se o
que os aparelhos ANUNCIAM sozinhos. Apple fala mDNS o tempo todo (AirDrop,
Handoff, AirPlay), entao um Mac ligado aparece sem precisar perguntar nada.

⚠️ Se ainda assim vier vazio, o bloqueio e' do Firewall do Windows para UDP
5353 de entrada, e nao ausencia de aparelho.
#>
[CmdletBinding()]
param([int]$Segundos = 20)

$porta = 5353
$grupo = [System.Net.IPAddress]::Parse('224.0.0.251')

$cli = New-Object System.Net.Sockets.UdpClient
$cli.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket,
                            [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
$cli.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $porta)))
try { $cli.JoinMulticastGroup($grupo) } catch { Write-Host "  (nao consegui entrar no grupo: $($_.Exception.Message))" }
$cli.Client.ReceiveTimeout = 1500

function Ler-Nomes {
    param([byte[]]$D)
    $sb = New-Object System.Text.StringBuilder
    $achados = @(); $i = 12
    while ($i -lt $D.Length) {
        $n = $D[$i]
        if ($n -eq 0) {
            if ($sb.Length -gt 0) { $achados += $sb.ToString(); [void]$sb.Clear() }
            $i++
        } elseif ($n -ge 192) { $i += 2 }
        elseif ($n -lt 64 -and ($i + $n) -lt $D.Length) {
            $p = [System.Text.Encoding]::UTF8.GetString($D, $i + 1, $n)
            if ($p -match '^[\x20-\x7E]+$') {
                if ($sb.Length -gt 0) { [void]$sb.Append('.') }
                [void]$sb.Append($p)
            }
            $i += $n + 1
        } else { $i++ }
    }
    if ($sb.Length -gt 0) { $achados += $sb.ToString() }
    return $achados
}

Write-Host "== escutando mDNS por $Segundos s =="
$porIP = @{}
$fim = (Get-Date).AddSeconds($Segundos)
while ((Get-Date) -lt $fim) {
    try {
        $de = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $d = $cli.Receive([ref]$de)
        $ip = $de.Address.ToString()
        if (-not $porIP.ContainsKey($ip)) { $porIP[$ip] = New-Object System.Collections.Generic.List[string] }
        foreach ($n in (Ler-Nomes $d)) {
            if ($n.Length -gt 3 -and $porIP[$ip] -notcontains $n) { $porIP[$ip].Add($n) }
        }
    } catch { }
}
try { $cli.DropMulticastGroup($grupo) } catch { }
$cli.Close()

if ($porIP.Count -eq 0) {
    Write-Host "  NADA recebido."
    Write-Host "  Isso aponta para o Firewall do Windows bloqueando UDP 5353 de entrada,"
    Write-Host "  e NAO para ausencia de aparelhos na rede."
    exit 2
}

foreach ($ip in ($porIP.Keys | Sort-Object { [int]($_ -split '\.')[3] })) {
    Write-Host ""
    Write-Host "  $ip"
    $nomes = $porIP[$ip] | Select-Object -Unique
    # Nome da maquina primeiro: e' o que interessa para apontar o Jenkins.
    $nomes | Where-Object { $_ -match '\.local$' -and $_ -notmatch '^_' } |
        ForEach-Object { Write-Host "      nome: $_" }
    $nomes | Where-Object { $_ -match '^_' } | Select-Object -First 8 |
        ForEach-Object { Write-Host "      svc : $_" }
}

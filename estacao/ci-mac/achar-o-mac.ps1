<#
.SYNOPSIS
Descobre quais maquinas da rede local sao Apple, e se aceitam SSH.

.DESCRIPTION
===========================================================================
Por que mDNS, e nao ping ou varredura de porta
===========================================================================
O macOS, por padrao, NAO responde ping e NAO abre porta nenhuma com os
compartilhamentos desligados. Numa varredura comum ele simplesmente nao
existe -- e a conclusao "o Mac nao esta na rede" sai errada.

⚠️ Ausencia em `ping` e em `Test-NetConnection` nao prova nada aqui. E' o
mesmo padrao de [[regra-nao-medido-nao-e-zero]]: nao medido virando zero.

O que ele responde, sempre, e' mDNS (Bonjour, 224.0.0.251:5353) -- e' assim
que o AirDrop e o AirPlay o acham. Uma consulta PTR reversa devolve o nome
`.local` da maquina, que ja' identifica o fabricante e serve de endereco
estavel para o Jenkins.

⚠️ E o endereco MAC tambem engana: Apple usa "Endereco Wi-Fi Privado", que
sorteia um MAC com o bit de administracao local ligado (segundo digito 2, 6,
A ou E). Procurar pelo OUI da Apple NAO acha um Mac em Wi-Fi.
===========================================================================
#>
[CmdletBinding()]
param(
    [string]$Rede = '192.168.15',
    [int]$EsperaMs = 2500
)

function Enviar-PerguntaMDNS {
    param([byte[]]$Pacote, [int]$EsperaMs)

    $cli = New-Object System.Net.Sockets.UdpClient
    $cli.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket,
                                [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $cli.Client.ReceiveTimeout = $EsperaMs
    $cli.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)))
    $destino = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse('224.0.0.251'), 5353)
    [void]$cli.Send($Pacote, $Pacote.Length, $destino)

    $respostas = @()
    $fim = (Get-Date).AddMilliseconds($EsperaMs)
    while ((Get-Date) -lt $fim) {
        try {
            $de = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $dados = $cli.Receive([ref]$de)
            $respostas += ,@($de.Address.ToString(), $dados)
        } catch { break }
    }
    $cli.Close()
    return $respostas
}

function Montar-PerguntaPTR {
    param([string]$Nome)
    # Cabecalho: ID=0, flags=0 (consulta padrao), 1 pergunta.
    $b = New-Object System.Collections.Generic.List[byte]
    $b.AddRange([byte[]]@(0,0, 0,0, 0,1, 0,0, 0,0, 0,0))
    foreach ($rotulo in $Nome.Split('.')) {
        if ($rotulo.Length -eq 0) { continue }
        $b.Add([byte]$rotulo.Length)
        $b.AddRange([System.Text.Encoding]::ASCII.GetBytes($rotulo))
    }
    $b.Add(0)
    # QTYPE=12 (PTR); QCLASS=1 com o bit alto ligado = "responda por unicast".
    $b.AddRange([byte[]]@(0,12, 0x80,1))
    return $b.ToArray()
}

function Ler-Nomes {
    param([byte[]]$Dados)
    # Extrai sequencias de rotulos legiveis. Nao e' um leitor de DNS completo
    # -- e' o suficiente para pescar o nome `.local`, que e' o que queremos.
    $texto = New-Object System.Text.StringBuilder
    $i = 12
    $achados = @()
    while ($i -lt $Dados.Length) {
        $n = $Dados[$i]
        if ($n -eq 0) {
            if ($texto.Length -gt 0) { $achados += $texto.ToString(); [void]$texto.Clear() }
            $i++
        } elseif ($n -ge 192) {
            $i += 2   # ponteiro de compressao: pula
        } elseif (($i + $n) -lt $Dados.Length -and $n -lt 64) {
            $parte = [System.Text.Encoding]::UTF8.GetString($Dados, $i + 1, $n)
            if ($parte -match '^[\x20-\x7E]+$') {
                if ($texto.Length -gt 0) { [void]$texto.Append('.') }
                [void]$texto.Append($parte)
            }
            $i += $n + 1
        } else { $i++ }
    }
    if ($texto.Length -gt 0) { $achados += $texto.ToString() }
    return $achados
}

Write-Host "== 1. perguntando por servicos Apple na rede (mDNS) =="
# `_companion-link` e `_rdlink` sao da Apple e ficam ligados mesmo com todos
# os compartilhamentos desligados -- por isso servem para ACHAR o Mac.
$servicos = @('_companion-link._tcp.local', '_rdlink._tcp.local',
              '_airplay._tcp.local', '_raop._tcp.local',
              '_ssh._tcp.local', '_sftp-ssh._tcp.local',
              '_device-info._tcp.local')
$vistos = @{}
foreach ($s in $servicos) {
    foreach ($r in (Enviar-PerguntaMDNS -Pacote (Montar-PerguntaPTR $s) -EsperaMs 1200)) {
        $ip = $r[0]
        if (-not $vistos.ContainsKey($ip)) { $vistos[$ip] = New-Object System.Collections.Generic.List[string] }
        foreach ($n in (Ler-Nomes $r[1])) {
            if ($n -match '\.local' -and $vistos[$ip] -notcontains $n) { $vistos[$ip].Add($n) }
        }
        if ($vistos[$ip] -notcontains "servico:$s") { $vistos[$ip].Add("servico:$s") }
    }
}

if ($vistos.Count -eq 0) {
    Write-Host "  nenhuma resposta mDNS"
} else {
    foreach ($ip in ($vistos.Keys | Sort-Object { [int]($_ -split '\.')[3] })) {
        Write-Host "  $ip"
        $vistos[$ip] | Select-Object -Unique | ForEach-Object { Write-Host "      $_" }
    }
}

Write-Host ""
Write-Host "== 2. nome .local de cada vizinho (PTR reverso) =="
$vizinhos = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -like "$Rede.*" -and $_.LinkLayerAddress -and
                   $_.LinkLayerAddress -ne '00-00-00-00-00-00' -and $_.IPAddress -notlike '*.255' } |
    Sort-Object { [int]($_.IPAddress -split '\.')[3] }

foreach ($v in $vizinhos) {
    $o = $v.IPAddress.Split('.')
    $rev = "$($o[3]).$($o[2]).$($o[1]).$($o[0]).in-addr.arpa"
    $nomes = @()
    foreach ($r in (Enviar-PerguntaMDNS -Pacote (Montar-PerguntaPTR $rev) -EsperaMs 900)) {
        $nomes += (Ler-Nomes $r[1]) | Where-Object { $_ -match '\.local' }
    }
    $mac = $v.LinkLayerAddress
    # Segundo digito 2/6/A/E => bit de administracao local => MAC sorteado
    # (tipico de "Endereco Wi-Fi Privado" da Apple).
    $sorteado = if ($mac -match '^.[26AEae]') { ' [MAC sorteado - tipico Apple]' } else { '' }
    $nome = if ($nomes) { ($nomes | Select-Object -Unique) -join ', ' } else { '(sem nome mDNS)' }
    Write-Host ("  {0,-15} {1}  {2}{3}" -f $v.IPAddress, $mac, $nome, $sorteado)
}

Write-Host ""
Write-Host "== 3. quem aceita SSH (porta 22) =="
foreach ($v in $vizinhos) {
    $ok = Test-NetConnection -ComputerName $v.IPAddress -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
    Write-Host ("  {0,-15} {1}" -f $v.IPAddress, $(if ($ok) { 'ABERTA' } else { 'fechada/filtrada' }))
}

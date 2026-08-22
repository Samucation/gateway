<#
.SYNOPSIS
Instala o túnel de HOMOLOGAÇÃO como serviço do Windows. Precisa de elevação.

.DESCRIPTION
⚠️ POR QUE ISTO EXISTE

O túnel de homologação rodava como PROCESSO comum, lançado pela pasta de
Inicialização. Isso tem duas falhas:

  1. só sobe quando o dono faz LOGON — a máquina ligada e sem ninguém logado
     fica sem homologação;
  2. se o processo morrer, ninguém o traz de volta.

🐞 A segunda aconteceu em 22/08/2026: o processo caiu, o túnel ficou SEM
CONEXÃO NENHUMA, e `urupix-hmg` passou a devolver 530 — com o Traefik
respondendo 200 localmente. O sintoma não aponta para o túnel: parece
aplicação fora do ar.

Como serviço, o Windows o sobe no boot e o reinicia sozinho se cair.

.NOTES
Rode com "Executar como administrador".
#>
$ErrorActionPreference = 'Continue'

$exe = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
$cfg = 'C:\Users\samue\.cloudflared\config-hmg.yml'

if (-not (Test-Path $exe)) { throw "nao achei o cloudflared em $exe" }
if (-not (Test-Path $cfg)) { throw "nao achei a config em $cfg" }

# ⚠️ O processo solto tem que morrer ANTES.
#
# Dois cloudflared com o MESMO túnel viram réplica: a Cloudflare divide o
# tráfego entre eles. Aqui os dois serviriam o mesmo cluster, então não haveria
# dano — mas a lição já custou caro no túnel de produção, e o hábito vale.
Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

& $exe --config $cfg service install
Start-Sleep -Seconds 5

$s = Get-Service cloudflared -ErrorAction SilentlyContinue
if (-not $s) { throw 'o servico nao foi criado' }

# 🐞 O `service install` do cloudflared registra o servico SEM os argumentos.
#
# O comando gravado fica so o executavel. Como o servico roda por LocalSystem,
# ele procura a configuracao em
# `C:\Windows\System32\config\systemprofile\.cloudflared\config.yml` -- que nao
# existe -- e encerra em seguida.
#
# ⚠️ O sintoma engana de propria: o servico aparece `Running` por um instante e
# o log diz "cloudflared terminated without error". SEM ERRO. E o tunel fica com
# ZERO conectores, enquanto o dominio devolve 530.
#
# Por isso o caminho da config entra no comando, explicitamente.
$comando = '"' + $exe + '" --config "' + $cfg + '" tunnel run'

# 🐞 E NÃO por `sc.exe config binPath= ...`.
#
# O comando tem aspas DENTRO do valor. O PowerShell 5.1 remonta a linha de
# comando ao chamar executável nativo e mutila essas aspas -- o sc.exe recebe
# lixo e recusa.
#
# ⚠️ A falha é MUDA: o serviço continua existindo com o comando velho, e a
# única forma de perceber é ir ler o registro. Eu perdi uma rodada inteira
# porque mandei a saída para `Out-Null`.
#
# O registro não passa por essa camada de remontagem.
$chave = 'HKLM:\SYSTEM\CurrentControlSet\Services\Cloudflared'
Set-ItemProperty -Path $chave -Name ImagePath -Value $comando

$gravado = (Get-ItemProperty -Path $chave -Name ImagePath).ImagePath
if ($gravado -ne $comando) { throw "o comando do servico nao foi gravado: $gravado" }

# ⚠️ Reinício automático nas TRÊS primeiras falhas, e não só na primeira.
# Uma queda por rede instável costuma vir em série; reiniciar uma vez só deixa
# o túnel no chão na segunda.
& sc.exe failure cloudflared reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null

Set-Service cloudflared -StartupType Automatic

# O serviço precisa RECOMEÇAR para ler o comando novo; quem já está de pé
# continua com o comando velho.
Stop-Service cloudflared -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Start-Service cloudflared -ErrorAction SilentlyContinue
Start-Sleep -Seconds 15

$s = Get-Service cloudflared
Write-Output ("servico: {0} | partida: {1}" -f $s.Status, $s.StartType)

# ⚠️ "Running" NÃO É PROVA.
#
# 🐞 Foi assim que este script me enganou duas vezes seguidas: o serviço subia,
# dizia `Running`, o log dizia "terminated without error" -- e o túnel ficava
# com ZERO conectores, com o domínio devolvendo 530.
#
# Serviço de pé prova que o Windows lançou o processo. Não prova que o processo
# achou a configuração, nem que ele conectou na Cloudflare. Só a resposta do
# domínio prova isso.
$url = 'https://urupix-hmg.cursodetecnologia.dev.br'
$codigo = 0
foreach ($tentativa in 1..6) {
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 25 -ErrorAction Stop
        $codigo = [int]$r.StatusCode
    } catch {
        $codigo = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    }
    Write-Output ("  tentativa {0}: {1}" -f $tentativa, $codigo)
    if ($codigo -eq 200) { break }
    Start-Sleep -Seconds 10
}

if ($codigo -ne 200) {
    throw "o servico esta de pe mas o tunel NAO serve ($url devolveu $codigo)"
}
Write-Output 'homologacao servindo pelo servico.'

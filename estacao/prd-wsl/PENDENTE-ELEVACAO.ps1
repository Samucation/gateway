# ===========================================================================
# O QUE FALTA E PRECISA DE ADMINISTRADOR
#
#     Clique com o botao direito -> "Executar com o PowerShell"
#     (ou:  powershell -ExecutionPolicy Bypass -File PENDENTE-ELEVACAO.ps1)
#
# ---------------------------------------------------------------------------
# So ha UMA coisa aqui: reiniciar o tunel para ele reler o `config.yml`.
#
# Tres dominios do Veltrixa apontavam para portas do Docker que morreram na
# virada para o k3s -- `ninjasystem` (4201), `ninjasystem-admin` (4200) e o
# Keycloak `ninjasystem-auth` (8085). Os tres devolviam 502 com as aplicacoes
# PERFEITAMENTE no ar dentro do cluster; era so o tunel entregando no vazio.
#
# O `config.yml` ja esta corrigido e VALIDADO (`cloudflared tunnel ingress
# validate` -> OK). Falta o servico reler, e parar servico exige elevacao:
# sem ela o `Restart-Service` falha com "Cannot open ... service on computer".
#
# ⚠️ O servico chama-se `NerdQuizTunnel` -- nome historico. Ele nao serve so o
# NerdQuiz: e o tunel da PRODUCAO INTEIRA. O outro (`Cloudflared`) serve os
# dominios `*-hmg` e nao tem nada com isto.
# ===========================================================================
$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  Precisa de Administrador. Reabrindo elevado..." -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
    exit 0
}

$cf = "C:\Program Files (x86)\cloudflared\cloudflared.exe"
$cfg = "C:\Users\samue\.cloudflared\config.yml"

Write-Host "== 1. conferindo o arquivo antes de reiniciar =="
# ⚠️ Validar ANTES. Reiniciar com config invalida troca tres dominios em 502
# por TODOS em 502 -- o cloudflared recusa subir e o servico fica parado.
& $cf --config $cfg tunnel ingress validate
if ($LASTEXITCODE -ne 0) { Write-Error "config invalida; NAO vou reiniciar"; exit 1 }

Write-Host "== 2. reiniciando o tunel da producao =="
Restart-Service NerdQuizTunnel -Force
Start-Sleep -Seconds 15

Write-Host "== 3. conferindo pelos dominios publicos =="
# A prova e o que o usuario ve, de fora, pela internet. "Servico Running" ja
# mentiu antes: o tunel sobe feliz apontando para porta onde nao ha ninguem.
$alvos = @{
    'ninjasystem.cursodetecnologia.dev.br'        = '200'
    'ninjasystem-admin.cursodetecnologia.dev.br'  = '200'
    'urupix.com.br'                               = '200'
    'sigma-financeiro.cursodetecnologia.dev.br'   = '200'
    'opuschat.cursodetecnologia.dev.br'           = '200'
    'quiz.cursodetecnologia.dev.br'               = '307'
}
$ruim = 0
foreach ($d in $alvos.Keys | Sort-Object) {
    $c = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 25 "https://$d/" 2>$null)
    $ok = ($c -eq $alvos[$d])
    if (-not $ok) { $ruim++ }
    $cor = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0,-46} {1}  (esperado {2})" -f $d, $c, $alvos[$d]) -ForegroundColor $cor
}

# E o console de admin do Keycloak tem de continuar FECHADO. Mexer no destino
# de um hostname com lista de caminhos e o jeito classico de abrir sem querer
# o que a lista fechava.
$adm = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 25 `
        'https://ninjasystem-auth.cursodetecnologia.dev.br/admin/master/console/' 2>$null)
if ($adm -eq '404') {
    Write-Host "  console de admin do Keycloak: 404 (fechado, como tem de ser)" -ForegroundColor Green
} else {
    Write-Host "  ⚠️ console de admin do Keycloak devolveu $adm -- deveria ser 404" -ForegroundColor Red
    $ruim++
}

Write-Host ""
if ($ruim -eq 0) {
    Write-Host "  ✅ tudo no ar. Nada mais pendente de elevacao." -ForegroundColor Green
} else {
    Write-Host "  ❌ $ruim alvo(s) fora do esperado." -ForegroundColor Red
    Write-Host "     Para voltar atras:  copy `"$cfg.antes-k3s-2026-08-24`" `"$cfg`"  e rode de novo."
}

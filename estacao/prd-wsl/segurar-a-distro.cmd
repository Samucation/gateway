@echo off
rem ===========================================================================
rem SEGURA A DISTRO DE PRODUCAO VIVA.
rem
rem 🐞 O WSL ENCERRA A DISTRO OCIOSA, E ISSO DERRUBA A PRODUCAO.
rem
rem Sem nenhum processo externo segurando, o WSL desliga a distro pouco depois
rem do ultimo comando terminar. O systemd para o k3s LIMPO -- entao nao ha
rem erro, nao ha crash, nao ha nada no log alem de "Deactivated successfully".
rem
rem ⚠️ E o proximo comando religa a distro, e o k3s leva ~10 MINUTOS para subir
rem (VACUUM do banco de estado + reconciliacao). Nesse meio tempo o cluster
rem inteiro esta fora, e quem olha ve "k3s activating" -- que parece defeito de
rem partida e e a distro tendo sido morta por ociosidade.
rem
rem Em 25/08/2026 isso derrubou a producao repetidamente, e demorou a aparecer
rem porque QUALQUER comando meu na distro a ressuscitava: o problema so se
rem manifestava nos intervalos em que ninguem mexia.
rem
rem `sleep infinity` e um processo externo permanente: enquanto ele viver, o
rem WSL nao encerra a distro.
rem
rem ---------------------------------------------------------------------------
rem POR QUE AQUI, E NAO NUMA TAREFA AGENDADA
rem ---------------------------------------------------------------------------
rem `Register-ScheduledTask` exige Administrador nesta maquina. A pasta de
rem Inicializacao roda no logon sem pedir elevacao, e para isto basta.
rem
rem Instalar (uma vez, sem Administrador):
rem
rem   copy "%~f0" "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\"
rem
rem Conferir se esta valendo:
rem
rem   powershell -c "Get-CimInstance Win32_Process -Filter ""Name='wsl.exe'"" | ? { $_.CommandLine -match 'sleep' }"
rem ===========================================================================
title producao WSL - nao feche esta janela

rem `-d prd` explicito: se a distro padrao mudar, isto continua segurando a
rem CERTA. Segurar a distro errada e o mesmo que nao segurar nenhuma.
:laco
wsl.exe -d prd -- sleep infinity

rem Se o `wsl.exe` retornar (distro reiniciada, WSL atualizado), tenta de novo
rem em vez de desistir em silencio -- desistir aqui devolve o problema inteiro.
timeout /t 15 /nobreak >nul
goto laco

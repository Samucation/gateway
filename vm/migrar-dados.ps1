# ===========================================================================
# MIGRA OS DADOS desta estação para o cluster da máquina remota.
#
#     .\vm\migrar-dados.ps1                     # todos
#     .\vm\migrar-dados.ps1 -Apenas urupix      # um só
#     .\vm\migrar-dados.ps1 -Conferir           # NÃO migra; só compara os dois lados
#
# ---------------------------------------------------------------------------
# ⚠️ ESTE SCRIPT RODA NA JANELA DO CORTE
# ---------------------------------------------------------------------------
# A ordem do dia é:
#
#   1. desligar o watchdog do túnel
#   2. parar o túnel aqui            <- o tráfego para; ninguém mais escreve
#   3. RODAR ESTE SCRIPT             <- os dados vão inteiros, sem corrida
#   4. subir o túnel na VM
#
# Rodar antes disso produz cópia VELHA: tudo que for escrito entre a cópia e o
# corte fica só aqui, e some do ponto de vista de quem usar o ambiente novo. Uma
# doação nesse intervalo seria dinheiro recebido que o sistema não conhece.
#
# É por isso que ele é feito para ser RÁPIDO e REPETÍVEL, não para ser rodado
# com antecedência.
#
# ---------------------------------------------------------------------------
# O QUE ELE NÃO FAZ, DE PROPÓSITO
# ---------------------------------------------------------------------------
# Não apaga nada na origem. A estação continua íntegra depois de rodar — é para
# ela que se volta se o corte falhar, e um script de migração que destrói a
# origem transforma um contratempo em incidente.
# ===========================================================================
param(
    # ⚠️ Vazio de proposito: a VM esta em DHCP e ja trocou de IP tres vezes num
    # dia. IP fixo aqui falhava com "Connection timed out" -- erro que parece
    # maquina fora do ar, e nao endereco trocado. Vazio, o `achar-vm.ps1`
    # descobre e CONFERE O HOSTNAME antes de devolver.
    [string]$Vm      = "",
    [string]$Usuario = "usuario",
    [string]$Chave   = "$env:USERPROFILE\.ssh\id_hmg_veltrixa",
    [string]$Apenas  = "",
    [switch]$Conferir
)

# 🐞 `Continue`, e nao `Stop`.
#
# No PowerShell 5.1, a saida de ERRO de um programa externo vira ErrorRecord.
# Com `Stop`, um aviso qualquer do `psql` ou do `pg_restore` -- coisa rotineira,
# nao falha -- MATA o script no meio de uma migracao. As falhas que importam sao
# conferidas explicitamente, comparando os dois lados.
$ErrorActionPreference = 'Continue'

if (-not $Vm) {
    $Vm = & (Join-Path $PSScriptRoot 'achar-vm.ps1')
    if (-not $Vm) { throw "nao achei a serverhomol na rede" }
    Write-Host "==> serverhomol em $Vm" -ForegroundColor Cyan
}

$ProgressPreference    = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# A TABELA. Acrescentar um projeto é uma linha.
#
# `Contar` é a consulta que prova que o dado chegou. Ela é DIFERENTE por projeto
# de propósito: contar linhas de `_prisma_migrations` provaria só que a migração
# rodou. O que importa é o dado de gente — usuário, pedido, ativo.
# ---------------------------------------------------------------------------
# ⚠️ A CONFERENCIA CONTA LINHAS, E NAO TABELAS.
#
# 🐞 Contava tabelas ate 21/08/2026, e isso e um teste que NAO TESTA NADA: a
# aplicacao roda as migracoes na partida e cria o esquema sozinha. As tabelas
# aparecem no destino tendo o dump chegado ou nao.
#
# Foi assim que dois projetos passaram como "CONFERE" com o banco vazio:
#
#   sprinklegames  13 tabelas = 13 tabelas, e 101 linhas contra ZERO
#                  (o pg_restore falhava: dump do PG 17, restore do PG 16)
#   veltrixa       63 tabelas = 63 tabelas, e app_user 10->0, cart 3->0,
#                  company 6->1
#
# O portal do sprinklegames ficou NO AR servindo banco vazio, e o sintoma que
# apareceu para o dono foi "algumas imagens estao faltando".
#
# ⚠️ Somar linhas de TODAS as tabelas e mais lento, e e o preco de a conferencia
# significar alguma coisa.
$PROJETOS = @(
    @{ Nome='urupix';       Origem='liveflow-db';       User='liveflow';   Db='liveflow'
       Ns='urupix';         Pod='urupix-postgres-0';    Secret='urupix-secrets'
       Contar='select (select count(*) from "User")::text||''/''||(select count(*) from "Donation")::text' }

    @{ Nome='opuschat';     Origem='opuschat-db';       User='plataforma'; Db='plataforma'
       Ns='opuschat';       Pod='opuschat-postgres-0';  Secret='opuschat-secrets'
       Contar='select coalesce(sum(c),0)::text from (select (xpath(''/row/c/text()'', query_to_xml(format(''select count(*) as c from %I.%I'', schemaname, tablename), false, true, '''')))[1]::text::bigint as c from pg_tables where schemaname not in (''pg_catalog'',''information_schema'')) t' }

    @{ Nome='plataforma';   Origem='plataforma-db';     User='plataforma'; Db='plataforma'
       Ns='plataforma';     Pod='plataforma-postgres-0'; Secret='plataforma-secrets'
       Contar='select coalesce(sum(c),0)::text from (select (xpath(''/row/c/text()'', query_to_xml(format(''select count(*) as c from %I.%I'', schemaname, tablename), false, true, '''')))[1]::text::bigint as c from pg_tables where schemaname not in (''pg_catalog'',''information_schema'')) t' }

    @{ Nome='sigmafin';     Origem='sigma-db';          User='sigma';      Db='sigma_financeiro'
       Ns='sigma-financeiro'; Pod='sigma-db-0';         Secret='sigma-financeiro-secrets'
       Contar='select coalesce(sum(c),0)::text from (select (xpath(''/row/c/text()'', query_to_xml(format(''select count(*) as c from %I.%I'', schemaname, tablename), false, true, '''')))[1]::text::bigint as c from pg_tables where schemaname not in (''pg_catalog'',''information_schema'')) t' }

    @{ Nome='sigmafin-sbx'; Origem='sigma-db-sandbox';  User='sigma';      Db='sigma_financeiro_sandbox'
       Ns='sigma-financeiro'; Pod='sigma-db-sandbox-0'; Secret='sigma-financeiro-secrets'
       Contar='select coalesce(sum(c),0)::text from (select (xpath(''/row/c/text()'', query_to_xml(format(''select count(*) as c from %I.%I'', schemaname, tablename), false, true, '''')))[1]::text::bigint as c from pg_tables where schemaname not in (''pg_catalog'',''information_schema'')) t' }

    @{ Nome='central-motor';  Origem='central-db-motor';  User='central'; Db='central'
       Ns='central-ia';       Pod='central-postgres-motor-0'; Secret='central-ia-secrets'
       Contar='select coalesce(sum(c),0)::text from (select (xpath(''/row/c/text()'', query_to_xml(format(''select count(*) as c from %I.%I'', schemaname, tablename), false, true, '''')))[1]::text::bigint as c from pg_tables where schemaname not in (''pg_catalog'',''information_schema'')) t' }

    @{ Nome='central-portal'; Origem='central-db-portal'; User='central'; Db='central_portal'
       Ns='central-ia';       Pod='central-postgres-portal-0'; Secret='central-ia-secrets'
       Contar='select coalesce(sum(c),0)::text from (select (xpath(''/row/c/text()'', query_to_xml(format(''select count(*) as c from %I.%I'', schemaname, tablename), false, true, '''')))[1]::text::bigint as c from pg_tables where schemaname not in (''pg_catalog'',''information_schema'')) t' }

    # ---- acrescentados em 21/08/2026, durante o corte ----------------------
    #
    # ⚠️ FALTAVAM. A tabela cobria 7 bancos e o corte precisa de 11. Sem estes,
    # apontar o trafego de `veltrixa` e `sprinklegames` para a VM entregaria
    # BANCO VAZIO com a aplicacao de pe: loja sem produto, login recusando --
    # e nenhuma mensagem dizendo "faltou migrar".
    @{ Nome='veltrixa';     Origem='veltrixa-postgres'; User='veltrixa'; Db='veltrixa_db'
       Ns='veltrixa';       Pod='veltrixa-postgres-0';  Secret='veltrixa-secrets'
       Contar='select coalesce(sum(c),0)::text from (select (xpath(''/row/c/text()'', query_to_xml(format(''select count(*) as c from %I.%I'', schemaname, tablename), false, true, '''')))[1]::text::bigint as c from pg_tables where schemaname not in (''pg_catalog'',''information_schema'')) t' }

    # ⚠️ O Keycloak tem banco PROPRIO, e e nele que moram os USUARIOS. Migrar o
    # veltrixa sem este deixaria a loja com os dados e ninguem conseguindo
    # entrar -- e "senha invalida" nao faz ninguem pensar em migracao.
    @{ Nome='veltrixa-keycloak'; Origem='veltrixa-keycloak-postgres'; User='keycloak'; Db='keycloak_db'
       Ns='veltrixa';            Pod='veltrixa-keycloak-postgres-0';  Secret='veltrixa-secrets'
       Contar='select coalesce(sum(c),0)::text from (select (xpath(''/row/c/text()'', query_to_xml(format(''select count(*) as c from %I.%I'', schemaname, tablename), false, true, '''')))[1]::text::bigint as c from pg_tables where schemaname not in (''pg_catalog'',''information_schema'')) t' }

    # ⚠️ Fiscal: aqui moram os certificados digitais, cifrados pela
    # NFE_VAULT_KEK. A chave tem que ser a MESMA dos dois lados -- com outra, os
    # certificados viram bytes sem uso, e o erro so aparece na hora de emitir.
    @{ Nome='veltrixa-nfe'; Origem='veltrixa-nfe-postgres'; User='nfe'; Db='nfe_db'
       Ns='veltrixa';       Pod='veltrixa-nfe-postgres-0';  Secret='veltrixa-secrets'
       Contar='select coalesce(sum(c),0)::text from (select (xpath(''/row/c/text()'', query_to_xml(format(''select count(*) as c from %I.%I'', schemaname, tablename), false, true, '''')))[1]::text::bigint as c from pg_tables where schemaname not in (''pg_catalog'',''information_schema'')) t' }

    @{ Nome='sprinklegames'; Origem='sprinklegames-postgres'; User='sprinkle'; Db='sprinklegames'
       Ns='sprinklegames';   Pod='sprinklegames-postgres-0'; Secret='sprinklegames-secrets'
       Contar='select coalesce(sum(c),0)::text from (select (xpath(''/row/c/text()'', query_to_xml(format(''select count(*) as c from %I.%I'', schemaname, tablename), false, true, '''')))[1]::text::bigint as c from pg_tables where schemaname not in (''pg_catalog'',''information_schema'')) t' }
)

function Log($m) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

$ssh = @('-i', $Chave, '-o', 'BatchMode=yes', "$Usuario@$Vm")
$carimbo = Get-Date -Format 'yyyyMMdd-HHmmss'

# A senha do banco de DESTINO vem do Secret do cluster, não de um arquivo aqui.
# Assim o script não guarda senha nenhuma, e não há um segundo lugar para ela
# ficar desatualizada.
function SenhaDestino($ns, $secret) {
    $chaves = @('POSTGRES_PASSWORD', 'MIDIA_DB_SENHA')
    foreach ($k in $chaves) {
        $v = (& ssh @ssh "sudo microk8s kubectl get secret $secret -n $ns -o jsonpath='{.data.$k}' 2>/dev/null | base64 -d") -join ''
        if ($v) { return $v }
    }
    throw "nao achei senha no secret $secret de $ns"
}

$alvos = $PROJETOS | Where-Object { -not $Apenas -or $_.Nome -eq $Apenas }
if (-not $alvos) { throw "projeto '$Apenas' nao existe na tabela" }

$falhas = 0

foreach ($p in $alvos) {
    Log "=== $($p.Nome) ==="

    # -----------------------------------------------------------------------
    # 1. Quanto dado existe na ORIGEM. É contra este número que a chegada é
    #    conferida — não contra "o comando não deu erro".
    # -----------------------------------------------------------------------
    # 🐞 O SQL vai por ENTRADA PADRAO, nao como argumento.
    #
    # A consulta precisa de aspas duplas (`"User"`, `"Donation"` -- o Postgres
    # dobra identificador sem aspas para minusculo, e o Prisma cria as tabelas
    # em CamelCase). Passando como argumento, o PowerShell mastiga as aspas ao
    # montar a linha de comando do programa externo, e o erro que chega e
    #
    #     ERROR: relation "donation" does not exist
    #
    # -- que manda procurar a tabela errada. Por stdin nao ha linha de comando
    # para mastigar.
    $antes = ($p.Contar | docker exec -i $p.Origem psql -U $p.User -d $p.Db -tA) -join ''
    $antes = $antes.Trim()
    Log "  origem: $antes"

    if ($Conferir) {
        $pw = SenhaDestino $p.Ns $p.Secret
        $dep = ($p.Contar | & ssh @ssh "sudo microk8s kubectl exec -i -n $($p.Ns) $($p.Pod) -- env PGPASSWORD='$pw' psql -U $($p.User) -d $($p.Db) -tA 2>/dev/null") -join ''
        $dep = $dep.Trim()
        $igual = if ($antes -eq $dep) { 'IGUAL' } else { 'DIVERGE' }
        Log "  destino: $dep   -> $igual"
        if ($antes -ne $dep) { $falhas++ }
        continue
    }

    # -----------------------------------------------------------------------
    # 2. O dump.
    #
    # `-Fc` (custom): comprimido, e o `pg_restore` consegue tirar UMA tabela
    # dele. Com SQL puro, restaurar uma tabela é editar um arquivo gigante.
    # -----------------------------------------------------------------------
    $arq = "$env:TEMP\mig-$($p.Nome)-$carimbo.dump"
    docker exec $p.Origem pg_dump -U $p.User -d $p.Db -Fc -f /tmp/mig.dump 2>$null
    docker cp "$($p.Origem):/tmp/mig.dump" $arq | Out-Null
    docker exec $p.Origem rm -f /tmp/mig.dump 2>$null | Out-Null

    $tam = (Get-Item $arq).Length
    # Os dois primeiros bytes de um dump `custom` são "PG". Tamanho parecido não
    # prova nada; a assinatura prova que o arquivo é o que se pensa.
    $cab = [System.IO.File]::ReadAllBytes($arq)[0..1]
    if ([char]$cab[0] + [char]$cab[1] -ne 'PG') { throw "$($p.Nome): dump sem assinatura PG" }
    Log ("  dump: {0} KB, assinatura PG ok" -f [math]::Round($tam/1KB,1))

    # -----------------------------------------------------------------------
    # 3. Levar e restaurar.
    #
    # 🐞 `scp`, e NUNCA `ssh "cat" | Set-Content`: o PowerShell converte a saída
    # de programa externo em TEXTO e corrompe binário EM SILÊNCIO. O dump
    # chegaria com tamanho parecido e não restauraria.
    # -----------------------------------------------------------------------
    & scp -i $Chave -o BatchMode=yes -q $arq "${Usuario}@${Vm}:/tmp/mig.dump" | Out-Null

    $pw = SenhaDestino $p.Ns $p.Secret

    # O banco é RECRIADO antes de restaurar.
    #
    # Restaurar por cima de um banco com esquema já criado (as migrações rodam
    # na partida da aplicação) produz centenas de erros de "já existe" e um
    # resultado meio-a-meio — que é pior que falhar, porque parece ter dado
    # certo. Recriar garante que o que ficou é exatamente o que veio.
    $recriar = @(
      "sudo microk8s kubectl exec -n $($p.Ns) $($p.Pod) -- env PGPASSWORD='$pw' psql -U $($p.User) -d postgres -c \""select pg_terminate_backend(pid) from pg_stat_activity where datname='$($p.Db)' and pid<>pg_backend_pid()\"" >/dev/null 2>&1",
      "sudo microk8s kubectl exec -n $($p.Ns) $($p.Pod) -- env PGPASSWORD='$pw' psql -U $($p.User) -d postgres -c 'drop database if exists \""$($p.Db)\""' >/dev/null 2>&1",
      "sudo microk8s kubectl exec -n $($p.Ns) $($p.Pod) -- env PGPASSWORD='$pw' psql -U $($p.User) -d postgres -c 'create database \""$($p.Db)\""' >/dev/null 2>&1"
    ) -join '; '
    & ssh @ssh $recriar | Out-Null

    # 🐞 `kubectl cp` NÃO serve para toda imagem: ele usa `tar` DENTRO do
    # container de destino. A do Postgres tem tar, então aqui funciona — mas a
    # do MinIO não tem, e ali a cópia falharia EM SILÊNCIO.
    & ssh @ssh "sudo microk8s kubectl cp /tmp/mig.dump $($p.Ns)/$($p.Pod):/tmp/mig.dump >/dev/null 2>&1"
    & ssh @ssh "sudo microk8s kubectl exec -n $($p.Ns) $($p.Pod) -- env PGPASSWORD='$pw' pg_restore -U $($p.User) -d $($p.Db) --no-owner --no-privileges /tmp/mig.dump 2>&1 | tail -3" | ForEach-Object { if ($_) { Log "    $_" } }
    & ssh @ssh "sudo microk8s kubectl exec -n $($p.Ns) $($p.Pod) -- rm -f /tmp/mig.dump >/dev/null 2>&1; rm -f /tmp/mig.dump"

    # -----------------------------------------------------------------------
    # 4. A CONFERÊNCIA. É ela que separa "rodou" de "funcionou".
    # -----------------------------------------------------------------------
    $depois = ($p.Contar | & ssh @ssh "sudo microk8s kubectl exec -i -n $($p.Ns) $($p.Pod) -- env PGPASSWORD='$pw' psql -U $($p.User) -d $($p.Db) -tA 2>/dev/null") -join ''
    $depois = $depois.Trim()

    if ($depois -eq $antes) {
        Log "  destino: $depois   -> CONFERE"
    } else {
        Log "  destino: $depois   -> ⚠️ DIVERGE de $antes"
        $falhas++
    }
    Remove-Item $arq -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# O sigma-midia é à parte: ele tem BANCO e BYTES.
#
# Fazer só o banco daria uma migração de aparência perfeita — todas as linhas
# no lugar — com TODAS as imagens quebradas. O banco guarda o ponteiro; o
# MinIO guarda o arquivo.
# ---------------------------------------------------------------------------
if (-not $Apenas -or $Apenas -eq 'sigma-midia') {
    Log "=== sigma-midia (banco + objetos) ==="
    Log "  ⚠️ este tem duas partes; use vm\migrar-midia.ps1"
}

Write-Output ""
if ($falhas) {
    Log "⚠️ $falhas projeto(s) divergiram. NAO siga com o corte."
    exit 1
}
Log "todos conferem. Origem intacta — a estacao continua servindo se precisar voltar."

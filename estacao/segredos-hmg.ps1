<#
.SYNOPSIS
Cria os Secrets do cluster de HOMOLOGAÇÃO desta estação.

.DESCRIPTION
⚠️ HOMOLOGAÇÃO NÃO RECEBE CREDENCIAL DE PAGAMENTO. NUNCA.

Esta é a decisão que sustenta o resto: as chaves de adquirente, de Mercado Pago
e de e-mail entram VAZIAS. Com elas preenchidas, um teste de doação cobraria uma
pessoa de verdade — e o teste teria passado, porque cobrar funcionou.

O `sigma-financeiro` daqui roda em `sandbox`, e a guarda de ambiente coerente do
próprio serviço recusa uma credencial `live` num ambiente `sandbox`. Mas guarda
é a segunda linha de defesa; a primeira é a credencial não estar aqui.

⚠️ As chaves de CIFRA são GERADAS, e diferentes das de produção.

`TOKEN_ENCRYPTION_KEY` e `AUTH_SECRET` protegem token de OAuth e sessão. Usar a
mesma dos dois lados faria um token cifrado em homologação valer em produção —
e uma sessão daqui abriria a conta de lá.

⚠️ São geradas UMA VEZ e guardadas no cluster. Regerar a cada execução
invalidaria tudo que foi cifrado antes: os streamers de teste apareceriam
desconectados, e a causa seria "rodei o script de novo".

.EXAMPLE
.\estacao\segredos-hmg.ps1
.\estacao\segredos-hmg.ps1 -Recriar    # descarta e gera de novo
#>
[CmdletBinding()]
param(
    [string]$Contexto = 'k3d-hmg',
    [switch]$Recriar
)

# 🐞 `Continue`, e NÃO `Stop`.
#
# No PowerShell 5.1 a saída de erro de um programa externo vira ErrorRecord. Com
# `Stop`, o `kubectl get secret` de um segredo que ainda NÃO EXISTE — que é o
# caso normal na primeira execução — mata o script:
#
#   Error from server (NotFound): secrets "urupix-secrets" not found
#
# Isso não é falha: é a resposta à pergunta "já existe?". As falhas que importam
# são conferidas por `$LASTEXITCODE`, explicitamente.
#
# ⚠️ Já documentei esta mesma armadilha em `vm/migrar-dados.ps1` e caí nela de
# novo aqui. O padrão é: script que chama executável externo usa `Continue`.
$ErrorActionPreference = 'Continue'

function NovaChave { -join ((1..64) | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] }) }

# ⚠️ Semente de TOTP tem alfabeto PRÓPRIO — base32, e não hexadecimal.
#
# `PLATFORM_ADMIN_TOTP` é lido por biblioteca de TOTP, que decodifica base32
# (RFC 4648: A-Z e 2-7). Uma chave hexadecimal passa pela decodificação sem
# reclamar, porque `0-9` e `a-f` são caracteres aceitos — e produz bytes
# ERRADOS. O aplicativo autenticador gera códigos que nunca conferem, e o erro
# aparece como "código inválido", que parece problema de relógio.
function NovaChaveBase32 { -join ((1..32) | ForEach-Object { 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'[(Get-Random -Maximum 32)] }) }

function Existe($ns, $nome) {
    & kubectl --context $Contexto get secret $nome -n $ns *> $null
    return ($LASTEXITCODE -eq 0)
}

function Aplicar($ns, $nome, $dados) {
    if ((Existe $ns $nome) -and -not $Recriar) {
        Write-Host ("  {0,-18} {1} ja existe (use -Recriar para trocar)" -f $ns, $nome)
        return
    }
    $linhas = foreach ($k in $dados.Keys) {
        $b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$dados[$k]))
        # ⚠️ Valor vazio precisa de `""`: em branco o YAML lê como NULO e o
        # kubectl NÃO cria a chave. O Pod então morre em
        # CreateContainerConfigError falando de contêiner, não de segredo.
        if ($b) { "  ${k}: $b" } else { "  ${k}: `"`"" }
    }
    $yaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: $nome
  namespace: $ns
type: Opaque
data:
$($linhas -join "`n")
"@
    $yaml | & kubectl --context $Contexto apply -f - *> $null
    if ($LASTEXITCODE -ne 0) { throw "falhou ao aplicar $nome em $ns" }
    Write-Host ("  {0,-18} {1} aplicado ({2} chaves)" -f $ns, $nome, $dados.Count)
}


# ⚠️ `-Recriar` REGENERA TUDO, e isso tem consequencia.
#
# 🐞 Usei `-Recriar` em 22/08/2026 so para acrescentar duas chaves ao
# sprinklegames, e ele trocou junto a senha do banco do urupix -- que ja tinha
# subido com a antiga. O Postgres guarda a senha no momento em que INICIALIZA o
# diretorio de dados; trocar o Secret depois nao muda nada la dentro, e o app
# passa a nao conseguir entrar no proprio banco.
#
# O sintoma engana: o Pod do banco fica `1/1 Running` (ele esta saudavel), e
# quem falha e a aplicacao, com erro de autenticacao.
#
# Em homologacao a saida e simples -- apagar o StatefulSet e o PVC e deixar a
# esteira recriar. Em producao isso seria perda de dados.
#
# ⚠️ Se voce so quer acrescentar UMA chave, edite o molde e rode SEM `-Recriar`:
# o script pula o que ja existe. Use `-Recriar` sabendo que os bancos de
# homologacao vao precisar ser recriados junto.

# ---------------------------------------------------------------------------
# A senha do banco é a MESMA dentro de cada namespace, e gerada aqui.
# ---------------------------------------------------------------------------
$pgUrupix = NovaChave
$pgSprink = NovaChave
$pgOpus     = NovaChave
$pgPlat     = NovaChave
$pgVeltrixa = NovaChave
$pgVeltKc   = NovaChave
$pgVeltNfe  = NovaChave
$pgSigma    = NovaChave
$pgMidia    = NovaChave
$s3Midia    = NovaChave
$rootMidia  = NovaChave

Aplicar 'urupix' 'urupix-secrets' ([ordered]@{
    POSTGRES_PASSWORD    = $pgUrupix
    DATABASE_URL         = "postgresql://liveflow:$pgUrupix@urupix-postgres:5432/liveflow"
    AUTH_SECRET          = (NovaChave)
    TOKEN_ENCRYPTION_KEY = (NovaChave)
    INTERNAL_CRON_SECRET = (NovaChave)

    # ---- pagamento: VAZIO de propósito ------------------------------------
    MP_ACCESS_TOKEN        = ''
    MP_PUBLIC_KEY          = ''
    MP_CLIENT_ID           = ''
    MP_CLIENT_SECRET       = ''
    MP_WEBHOOK_SECRET      = ''
    MP_DEFAULT_PAYER_EMAIL = 'teste@exemplo.invalido'
    SIGMA_CLIENT_ID        = ''
    SIGMA_CLIENT_SECRET    = ''
    SIGMA_WEBHOOK_SECRET   = ''
    WOOVI_APP_ID           = ''
    WOOVI_ENV              = 'sandbox'
    WOOVI_PLATFORM_PIXKEY  = ''

    # ---- envio para fora: VAZIO -------------------------------------------
    # ⚠️ Sem isto, homologação manda e-mail e push para gente de verdade — a
    # base de teste tem endereços reais, copiados do dump.
    RESEND_API_KEY         = ''
    EMAIL_FROM             = 'nao-responda@exemplo.invalido'
    FCM_SERVICE_ACCOUNT_B64 = ''
    VAPID_PUBLIC_KEY       = ''
    VAPID_PRIVATE_KEY      = ''
    VAPID_SUBJECT          = 'mailto:teste@exemplo.invalido'

    # ---- login social: vazio (entra pelo caminho de e-mail em hmg) --------
    AUTH_GOOGLE_ID         = ''
    AUTH_GOOGLE_SECRET     = ''
    GOOGLE_APP_ALLOWED_PROJECTS = ''

    # ---- serviços vizinhos -------------------------------------------------
    MIDIA_API_KEY          = ''
    MIDIA_PORTAL_SENHA     = ''
    CENTRAL_CHAVE          = ''
    GATEWAY_API_CHAVE      = ''
    SIGMA_MERCADO          = 'false'
    SIGMA_DOACAO           = 'false'
    MULTI_CHANNEL_ATTRIBUTION = 'false'
    OVERLAY_FOLLOW_ACTIVE  = 'true'
})

Aplicar 'sprinklegames' 'sprinklegames-secrets' ([ordered]@{
    POSTGRES_PASSWORD = $pgSprink
    DATABASE_URL      = "postgres://sprinkle:$pgSprink@sprinklegames-postgres:5432/sprinklegames"
    JWT_SECRET        = (NovaChave)
    RESEND_API_KEY    = ''

    # 🐞 Faltavam, e o Pod morria em CreateContainerConfigError:
    #
    #   couldn't find key SEED_ADMIN_USERNAME in Secret sprinklegames-secrets
    #
    # ⚠️ Eu tinha escrito o Secret olhando o `.env` do projeto, e nao o que o
    # DEPLOYMENT referencia. Sao listas diferentes: o Deployment pede cinco
    # chaves por `secretKeyRef`, e duas delas nao estao no `.env`.
    #
    # A licao: a fonte da verdade sobre "quais chaves o Pod precisa" e o
    # manifesto, nao o arquivo de ambiente do desenvolvedor.
    SEED_ADMIN_USERNAME = 'admin-hmg'

    # ⚠️ Senha GERADA, e diferente da de producao. Este ambiente e alcancavel
    # pela internet (`sprinklegames-hmg.cursodetecnologia.dev.br`); repetir a
    # senha do admin de producao aqui daria acesso ao painel real a quem
    # descobrisse a de teste.
    SEED_ADMIN_PASSWORD = (NovaChave)
})

# ---------------------------------------------------------------------------
# OpusChat e Plataforma
# ---------------------------------------------------------------------------
# ⚠️ Sao DOIS namespaces com a MESMA lista de chaves e o MESMO nome de banco
# (`plataforma`). Nao sao o mesmo servico: o `opuschat` e o produto de chat e o
# `plataforma` e o ERP, e cada um tem o seu Postgres. Copiar a URL de um para o
# outro faz o app subir e falar com o banco ERRADO -- e como o esquema e o
# mesmo, ele nao reclama.
foreach ($p in @(
    @{ Ns = 'opuschat';   Senha = $pgOpus; Host_ = 'opuschat-postgres' },
    @{ Ns = 'plataforma'; Senha = $pgPlat; Host_ = 'plataforma-postgres' }
)) {
    Aplicar $p.Ns "$($p.Ns)-secrets" ([ordered]@{
        POSTGRES_PASSWORD = $p.Senha
        DATABASE_URL      = "postgres://plataforma:$($p.Senha)@$($p.Host_):5432/plataforma?sslmode=disable"
        JWT_SECRET        = (NovaChave)

        # Cofre de credenciais do proprio produto. Chave NOVA em homologacao: o
        # que estiver cifrado com a de producao fica ilegivel aqui, que e
        # exatamente o que se quer.
        COFRE_CHAVE       = (NovaChave)

        ATENDIMENTO_WEBHOOK_SECRET = (NovaChave)
        PLATFORM_ADMIN_TOTP        = (NovaChaveBase32)

        # ---- envio para fora e vizinhos: VAZIO -----------------------------
        RESEND_API_KEY = ''
        CENTRAL_CHAVE  = ''
    })
}

# ---------------------------------------------------------------------------
# Veltrixa (app + Keycloak + NF-e)
# ---------------------------------------------------------------------------
Aplicar 'veltrixa' 'veltrixa-secrets' ([ordered]@{
    POSTGRES_PASSWORD       = $pgVeltrixa
    JDBC_DATABASE_USERNAME  = 'veltrixa'
    JDBC_DATABASE_PASSWORD  = $pgVeltrixa

    KEYCLOAK_DB_PASSWORD    = $pgVeltKc
    KEYCLOAK_ADMIN_USER     = 'admin'
    KEYCLOAK_ADMIN_PASSWORD = (NovaChave)

    # Conta que a API usa para falar com o Keycloak. Em producao o usuario e
    # literalmente `trocar` -- divida anotada la, nao replicada aqui.
    KEYCLOAK_AUTH_USER      = 'veltrixa-api-hmg'
    KEYCLOAK_AUTH_PASS      = (NovaChave)

    KEYCLOAK_CLIENT_SECRET       = (NovaChave)
    KEYCLOAK_SEED_ADMIN_PASSWORD = (NovaChave)

    NFE_POSTGRES_PASSWORD   = $pgVeltNfe

    # ⚠️ Chave-mestra dos CERTIFICADOS DIGITAIS da NF-e.
    #
    # Em producao ela decifra certificado A1 de cliente real. Aqui e gerada, e
    # isso e proposital: se um dump de producao vier parar neste ambiente, os
    # certificados ficam ilegiveis em vez de utilizaveis.
    #
    # ⚠️ O sintoma de chave trocada engana -- o servico sobe, responde, e trata
    # o certificado como "nao configurado". Sem erro nenhum. Se voce ver isso em
    # PRODUCAO, a causa quase certa e chave trocada, nao certificado faltando.
    NFE_VAULT_KEK           = (NovaChave)

    # ---- pagamento: VAZIO de proposito ------------------------------------
    SIGMA_CLIENT_ID      = ''
    SIGMA_CLIENT_SECRET  = ''
    SIGMA_WEBHOOK_SECRET = ''
    SIGMA_RECEIVER_ID    = ''

    MIDIA_API_KEY        = ''
})

# ---------------------------------------------------------------------------
# Sigma Financeiro
# ---------------------------------------------------------------------------
# ⚠️ ESTE E O SERVICO QUE MOVE DINHEIRO. Nenhuma credencial de adquirente entra
# aqui, em hipotese nenhuma.
#
# A garantia nao depende so de deixar campos vazios: a `TOKEN_ENCRYPTION_KEY` e
# GERADA. As credenciais dos adquirentes ficam cifradas dentro do banco (em
# `Receiver.credentialsEnc`), entao mesmo que um dump de producao seja
# restaurado aqui por engano, elas nao decifram.
Aplicar 'sigma-financeiro' 'sigma-financeiro-secrets' ([ordered]@{
    POSTGRES_PASSWORD     = $pgSigma
    DATABASE_URL          = "postgresql://sigma:$pgSigma@sigma-db:5432/sigma_financeiro?schema=public"
    DATABASE_URL_PRODUCAO = "postgresql://sigma:$pgSigma@sigma-db:5432/sigma_financeiro?schema=public"
    DATABASE_URL_SANDBOX  = "postgresql://sigma:$pgSigma@sigma-db-sandbox:5432/sigma_financeiro_sandbox?schema=public"

    AUTH_SECRET           = (NovaChave)
    TOKEN_ENCRYPTION_KEY  = (NovaChave)
    SIGMA_WEBHOOK_TOKEN   = (NovaChave)

    # ---- login social: vazio (entra pelo caminho de e-mail em hmg) --------
    GOOGLE_CLIENT_ID      = ''
    GOOGLE_CLIENT_SECRET  = ''
})

# ---------------------------------------------------------------------------
# Sigma Midia (banco + MinIO + imgproxy)
# ---------------------------------------------------------------------------
Aplicar 'sigma-midia' 'sigma-midia-secrets' ([ordered]@{
    MIDIA_DB_SENHA      = $pgMidia

    MINIO_ROOT_USER     = 'midia-root'
    MINIO_ROOT_PASSWORD = $rootMidia
    MIDIA_S3_APP_USER   = 'sigma-midia-app'
    MIDIA_S3_APP_SENHA  = $s3Midia

    # ⚠️ Credencial repetida em formato de URL, para o cliente `mc`.
    #
    # Ela tem que casar com MIDIA_S3_APP_USER/SENHA acima. Sao o MESMO segredo
    # escrito duas vezes; trocar um e esquecer o outro faz o `mc` falhar na
    # criacao do balde, e o portal sobe sem lugar para gravar imagem.
    MC_HOST_MINIO       = "http://sigma-midia-app:$s3Midia@sigma-midia-minio:9000"

    # ⚠️ Chave e sal do imgproxy sao lidos como HEXADECIMAL. `NovaChave` ja
    # devolve 64 caracteres hex; qualquer coisa fora desse alfabeto faz o
    # imgproxy recusar a assinatura das URLs e devolver 403 em toda imagem.
    MIDIA_IMG_CHAVE     = (NovaChave)
    MIDIA_IMG_SAL       = (NovaChave)

    MIDIA_ADMIN_EMAIL   = 'admin-hmg@exemplo.invalido'
    MIDIA_ADMIN_SENHA   = (NovaChave)
})

Write-Host ''
Write-Host '⚠️ Pagamento e envio para fora ficaram VAZIOS de proposito.' -ForegroundColor Yellow
Write-Host '   Homologacao nao cobra ninguem e nao manda e-mail para gente de verdade.'

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

Write-Host ''
Write-Host '⚠️ Pagamento e envio para fora ficaram VAZIOS de proposito.' -ForegroundColor Yellow
Write-Host '   Homologacao nao cobra ninguem e nao manda e-mail para gente de verdade.'

#!/usr/bin/env bash
# ===========================================================================
# Cria os Secrets de producao no k3s, a partir dos `.env` dos projetos.
#
#     bash criar-segredos.sh                  # todos
#     bash criar-segredos.sh sigma-financeiro # so um
# ===========================================================================
#
# ⚠️ NENHUM VALOR APARECE NA TELA NEM VAI PARA ARQUIVO.
#
# O YAML e montado e entregue ao `kubectl` pela ENTRADA. Como argumento de
# linha de comando, cada segredo apareceria em `ps` para qualquer usuario da
# maquina e ficaria no historico do shell.
#
# ---------------------------------------------------------------------------
# 🐞 O ENDERECO DO BANCO PRECISA SER REESCRITO, E ESQUECER ISSO NAO DA ERRO
# ---------------------------------------------------------------------------
# O `.env` dos projetos aponta para `localhost:5434`, `localhost:5438` e afins
# -- o Postgres publicado pelo Docker na estacao. Dentro de um Pod,
# `localhost` e o PROPRIO Pod: a conexao e recusada, o app trata como "banco
# indisponivel" e fica reiniciando.
#
# Aqui cada `DATABASE_URL` e reapontada para o Service do cluster.
set -uo pipefail

REPOS=/mnt/e/Desenvolvimento/Dev/Workspace
alvo="${1:-}"
falhas=0

# projeto | namespace | nome-do-secret | chaves (espaco) | servico-do-banco
LISTA=$(cat <<'FIM'
sigma-financeiro|sigma-financeiro|sigma-financeiro-secrets|AUTH_SECRET DATABASE_URL DATABASE_URL_SANDBOX GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET POSTGRES_PASSWORD SIGMA_WEBHOOK_TOKEN TOKEN_ENCRYPTION_KEY|sigma-db
live-flow|urupix|urupix-secrets|AUTH_SECRET DATABASE_URL INTERNAL_CRON_SECRET POSTGRES_PASSWORD TOKEN_ENCRYPTION_KEY|urupix-postgres
sprinklegames-portal|sprinklegames|sprinklegames-secrets|DATABASE_URL JWT_SECRET POSTGRES_PASSWORD RESEND_API_KEY SEED_ADMIN_PASSWORD SEED_ADMIN_USERNAME|sprinklegames-postgres
opuschat|opuschat|opuschat-secrets|ATENDIMENTO_WEBHOOK_SECRET CENTRAL_CHAVE COFRE_CHAVE DATABASE_URL JWT_SECRET PLATFORM_ADMIN_TOTP POSTGRES_PASSWORD RESEND_API_KEY|opuschat-postgres
cafe-mobile-erp|plataforma|plataforma-secrets|ATENDIMENTO_WEBHOOK_SECRET CENTRAL_CHAVE COFRE_CHAVE DATABASE_URL JWT_SECRET PLATFORM_ADMIN_TOTP POSTGRES_PASSWORD RESEND_API_KEY|plataforma-postgres
central-ia|central-ia|central-ia-secrets|COFRE_CHAVE DATABASE_URL_MOTOR DATABASE_URL_PORTAL MOTOR_SEGREDO POSTGRES_PASSWORD RESEND_API_KEY TOKEN_ENCRYPTION_KEY|central-postgres-motor
sigma-midia|sigma-midia|sigma-midia-secrets|MC_HOST_MINIO MIDIA_ADMIN_EMAIL MIDIA_ADMIN_SENHA MIDIA_DB_SENHA MIDIA_IMG_CHAVE MIDIA_IMG_SAL MIDIA_S3_APP_SENHA MIDIA_S3_APP_USER MINIO_ROOT_PASSWORD MINIO_ROOT_USER|sigma-midia-postgres
system-api|veltrixa|veltrixa-secrets|KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_ADMIN_USER KEYCLOAK_CLIENT_SECRET KEYCLOAK_DB_PASSWORD KEYCLOAK_SEED_ADMIN_PASSWORD NFE_POSTGRES_PASSWORD NFE_VAULT_KEK POSTGRES_PASSWORD|veltrixa-postgres
FIM
)

# ---------------------------------------------------------------------------
# O COFRE — segredos que NAO vêm de lugar nenhum e precisam existir
# ---------------------------------------------------------------------------
#
# Alguns valores nao estao no `.env` porque o `docker-compose` tinha um padrao
# embutido para eles. Copiar esse padrao seria levar a senha de exemplo do
# repositorio para dentro da producao nova.
#
# ⚠️ E o valor precisa ser ESTAVEL entre execucoes: sortear de novo a cada
# rodada trocaria a senha do banco embaixo de um Postgres que ja tem dados, e
# o app pararia de conectar sem nada ter mudado no codigo.
#
# Por isso ele e guardado -- fora do git, modo 600, na propria distro.
COFRE=/var/lib/prd-segredos
mkdir -p "$COFRE" && chmod 700 "$COFRE"

sortear_e_guardar() {
  local proj="$1" chave="$2" arq="$COFRE/$proj.env" valor
  if [ -f "$arq" ]; then
    valor=$(grep -m1 -E "^${chave}=" "$arq" 2>/dev/null) || valor=""
    if [ -n "$valor" ]; then printf '%s' "${valor#*=}"; return 0; fi
  fi
  # 24 caracteres de /dev/urandom, so alfanumericos: senha longa que atravessa
  # URL, YAML e linha de comando sem precisar de escape.
  valor=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
  printf '%s=%s\n' "$chave" "$valor" >> "$arq"
  chmod 600 "$arq"
  printf '%s' "$valor"
}

# ---------------------------------------------------------------------------
# 🐞 `?sslmode=disable` — SEM ISSO O APP NAO CONECTA, E O ERRO CULPA O SERVIDOR
# ---------------------------------------------------------------------------
#     Server does not support SSL, but it was required (default configuration)
#
# O driver de Postgres do Dart EXIGE TLS por padrao. O Postgres do cluster nao
# tem TLS -- e nao precisa: o trafego nao sai da rede do cluster.
#
# ⚠️ Quem resolvia isso era o `docker-compose`, que montava a URL com
# `?sslmode=disable` embutido. O `.env` guarda a URL de DESENVOLVIMENTO, sem o
# parametro, e ao montar o Secret a partir dele a exigencia voltava.
#
# A mensagem manda olhar para o servidor ("does not support SSL") quando o que
# esta errado e a expectativa do CLIENTE.
sem_ssl() {
  local url="$1"
  case "$url" in
    *sslmode=*) printf '%s' "$url" ;;
    *\?*)       printf '%s&sslmode=disable' "$url" ;;
    *)          printf '%s?sslmode=disable' "$url" ;;
  esac
}

# Le UMA variavel do .env sem executar o arquivo.
#
# ⚠️ `source` seria mais curto e perigoso: um `.env` com `$(...)` ou crase
# executaria comando com o usuario que roda isto -- que aqui e o root.
ler_env() {
  local arquivo="$1" chave="$2" linha
  linha=$(grep -m1 -E "^[[:space:]]*${chave}=" "$arquivo" 2>/dev/null) || return 1
  linha="${linha#*=}"

  # 🐞 O RETORNO DE CARRO VEM PRIMEIRO, E POR UM MOTIVO CARO.
  #
  # Os `.env` foram escritos no Windows, entao terminam em CRLF. O `\r` fica
  # GRUDADO no fim do valor, e ai a retirada de aspas abaixo nao acha aspa
  # nenhuma -- o ultimo caractere e o `\r`, nao a `"`.
  #
  # O estrago foi este, no urupix:
  #
  #   Datasource "db": PostgreSQL database "liveflow%22" ...
  #   ERROR: unterminated quoted identifier at or near ""liveflow"""
  #
  # A aspa sobreviveu ate dentro do nome do banco, virou `%22` na URL, e o
  # Prisma reclamou de identificador nao terminado. Nada na mensagem aponta
  # para "o arquivo tem CRLF".
  linha="${linha%$'\r'}"

  # tira aspas das pontas, se houver
  linha="${linha%\"}"; linha="${linha#\"}"
  linha="${linha%\'}"; linha="${linha#\'}"
  printf '%s' "$linha"
}

while IFS='|' read -r proj ns nome chaves servico; do
  [ -n "$proj" ] || continue
  [ -z "$alvo" ] || [ "$alvo" = "$proj" ] || continue

  env_arq="$REPOS/$proj/.env"
  if [ ! -f "$env_arq" ]; then
    echo "  $proj: SEM .env em $env_arq"
    falhas=$((falhas+1)); continue
  fi

  kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns" >/dev/null 2>&1

  corpo="apiVersion: v1
kind: Secret
metadata:
  name: $nome
  namespace: $ns
type: Opaque
stringData:"

  faltando=""
  vazias=""
  for k in $chaves; do
    v=$(ler_env "$env_arq" "$k") || v=""

    # ⚠️ DECLARADA-E-VAZIA e diferente de AUSENTE, e confundir as duas erra
    # para os dois lados.
    #
    # `GOOGLE_CLIENT_ID=` no `.env` quer dizer "esta funcionalidade nao esta
    # configurada" -- e a producao de hoje roda assim. Tratar como falta
    # deixaria a chave fora do Secret, e o Pod nao subiria
    # (`CreateContainerConfigError`).
    #
    # Ja uma chave que NAO aparece no arquivo e lacuna de verdade, e essa
    # continua sendo reportada.
    #
    # 🐞 Ate a correcao do CRLF as duas eram indistinguiveis: o `\r` sozinho
    # fazia um valor vazio parecer preenchido.
    if grep -qE "^[[:space:]]*${k}=" "$env_arq" 2>/dev/null; then declarada=1; else declarada=0; fi

    # -----------------------------------------------------------------------
    # APELIDOS — a mesma coisa com nome diferente dos dois lados
    # -----------------------------------------------------------------------
    #
    # ⚠️ O nome no manifesto do Kubernetes nem sempre e o nome no `.env`. O
    # `.env` nasceu para o `docker-compose`, e o compose renomeia no caminho
    # (`MINIO_ROOT_USER: ${MIDIA_S3_CHAVE:-midia}`).
    #
    # 🐞 Sem esta tabela, a chave sai VAZIA no Secret e o Pod sobe assim
    # mesmo -- com credencial em branco. No MinIO isso e um balde que recusa
    # tudo; no Keycloak, um administrador que nao entra. Nos dois casos o
    # sintoma aparece longe: "acesso negado", e nao "faltou configurar".
    if [ -z "$v" ]; then
      case "$k" in
        MINIO_ROOT_USER)
          v=$(ler_env "$env_arq" MIDIA_S3_CHAVE) || v=""
          # Mesmo caso do `MIDIA_DB_SENHA`: ausente no `.env`, o compose cai no
          # padrao `midia`. Aqui vira um nome proprio, guardado no cofre.
          [ -z "$v" ] && v=$(sortear_e_guardar "$proj" MINIO_ROOT_USER) ;;
        MINIO_ROOT_PASSWORD)
          v=$(ler_env "$env_arq" MIDIA_S3_SEGREDO) || v=""
          [ -z "$v" ] && v=$(sortear_e_guardar "$proj" MINIO_ROOT_PASSWORD) ;;
        KEYCLOAK_ADMIN_USER) v=$(ler_env "$env_arq" KEYCLOAK_ADMIN)   || v="" ;;
        KEYCLOAK_SEED_ADMIN_PASSWORD)
          v=$(ler_env "$env_arq" KEYCLOAK_ADMIN_PASSWORD) || v="" ;;
        MIDIA_DB_SENHA)
          # ⚠️ Deliberadamente NAO herda o padrao do compose.
          #
          # 🔴 ACHADO: o `.env` do sigma-midia nao define `MIDIA_DB_SENHA` nem
          # `MIDIA_S3_CHAVE`/`MIDIA_S3_SEGREDO`. O compose entao cai nos
          # padroes dele -- `midia-local` e `midia-segredo-local`. Ou seja: a
          # producao de hoje roda o Postgres e o MinIO com a SENHA DE EXEMPLO,
          # a mesma que esta no repositorio publico.
          #
          # Copiar isso para ca perpetuaria o problema. Aqui a senha e
          # SORTEADA e guardada em `$COFRE`, fora do git.
          v=$(sortear_e_guardar "$proj" "$k") ;;
      esac
      [ -n "$v" ] && echo "  $proj: $k veio de um apelido do .env"
    fi

    # -----------------------------------------------------------------------
    # DERIVADAS — montadas a partir do que existe
    # -----------------------------------------------------------------------
    if [ -z "$v" ]; then
      case "$k" in
        DATABASE_URL_MOTOR)
          # O `.env` do central-ia guarda a senha, nao a URL: quem monta a
          # string de conexao e o compose. No cluster quem monta e isto.
          senha=$(ler_env "$env_arq" POSTGRES_PASSWORD) || senha=""
          [ -n "$senha" ] && v="postgresql://central:${senha}@central-postgres-motor:5432/central" ;;
        DATABASE_URL_PORTAL)
          # Mesmo caso, outro banco: o portal tem base propria.
          senha=$(ler_env "$env_arq" POSTGRES_PASSWORD) || senha=""
          [ -n "$senha" ] && v="postgresql://central:${senha}@central-postgres-portal:5432/central_portal" ;;
        MOTOR_SEGREDO)
          # ⚠️ E o segredo que o PORTAL usa para falar com o MOTOR -- os dois
          # leem a mesma chave. Se cada lado tivesse a sua, o portal receberia
          # 401 do motor e o sintoma seria "a IA nao responde".
          v=$(ler_env "$env_arq" MOTOR_SEGREDO) || v=""
          [ -z "$v" ] && v=$(sortear_e_guardar "$proj" MOTOR_SEGREDO) ;;
        MC_HOST_MINIO)
          # O `mc` (cliente do MinIO) recebe o servidor como UMA url com
          # credencial embutida. Ela nao existe em lugar nenhum: e composta a
          # partir das credenciais de raiz -- as MESMAS que acabaram de ser
          # resolvidas acima, senao o cliente nao entraria no proprio servidor.
          u=$(ler_env "$env_arq" MIDIA_S3_CHAVE)   || u=""
          [ -z "$u" ] && u=$(sortear_e_guardar "$proj" MINIO_ROOT_USER)
          w=$(ler_env "$env_arq" MIDIA_S3_SEGREDO) || w=""
          [ -z "$w" ] && w=$(sortear_e_guardar "$proj" MINIO_ROOT_PASSWORD)
          [ -n "$u" ] && [ -n "$w" ] && v="http://${u}:${w}@sigma-midia-minio:9000" ;;
        PLATFORM_ADMIN_TOTP)
          # ⚠️ OPCIONAL de verdade: o compose declara `${PLATFORM_ADMIN_TOTP:-}`,
          # ou seja, vazio e um valor valido. Vai como vazio em vez de faltar,
          # porque `secretKeyRef` de chave AUSENTE impede o Pod de subir.
          v="" ; opcional=1 ;;
      esac
      [ -n "$v" ] && echo "  $proj: $k derivada"
    fi

    # ⚠️ `POSTGRES_PASSWORD` NAO existe no `.env`, e nem deveria.
    #
    # Na estacao o Postgres e um conteiner ja criado; o `.env` so guarda a URL
    # de conexao. No cluster o banco NASCE junto, e o StatefulSet precisa saber
    # que senha atribuir ao usuario.
    #
    # 🐞 Inventar uma senha aqui daria um banco que sobe feliz e um app que
    # nunca conecta -- "password authentication failed", com as duas metades
    # aparentemente configuradas. Ela e EXTRAIDA da propria `DATABASE_URL`,
    # que e a unica fonte que sabe a verdade.
    if [ -z "$v" ] && [ "$k" = "POSTGRES_PASSWORD" ]; then
      url=$(ler_env "$env_arq" DATABASE_URL) || url=""
      # ⚠️ Corte de texto puro, e nao `sed`.
      #
      # 🐞 A primeira versao usava grupo de captura, e o `` NAO
      # sobreviveu a camada de escape com que o arquivo foi editado: virou um
      # byte de controle, a substituicao ficou VAZIA e a senha foi gravada em
      # branco -- sem erro nenhum. O banco subiria com uma senha e o app com
      # outra, e a mensagem seria "password authentication failed".
      resto="${url#*://}"        # usuario:senha@host:porta/base
      credencial="${resto%%@*}"  # usuario:senha
      v="${credencial#*:}"       # senha
      [ -n "$v" ] && echo "  $proj: POSTGRES_PASSWORD derivada da DATABASE_URL"
    fi

    # ⚠️ Chave marcada como opcional entra VAZIA, e nao fica de fora.
    #
    # 🐞 `secretKeyRef` que aponta para chave AUSENTE impede o Pod de subir --
    # ele fica em `CreateContainerConfigError`, que nao diz qual chave falta.
    # Vazia, o container sobe e a aplicacao trata a ausencia como ela ja
    # trataria no compose.
    if [ -z "$v" ] && [ "${opcional:-0}" != "1" ] && [ "$declarada" != "1" ]; then
      faltando="$faltando $k"; opcional=0; continue
    fi
    [ -z "$v" ] && [ "$declarada" = "1" ] && vazias="$vazias $k"
    opcional=0

    # ⚠️ A reescrita do host do banco. `localhost`/`127.0.0.1` viram o Service.
    case "$k" in
      DATABASE_URL)
        v=$(printf '%s' "$v" | sed -E "s#@(localhost|127\.0\.0\.1):[0-9]+#@${servico}:5432#")
        v=$(sem_ssl "$v") ;;
      DATABASE_URL_SANDBOX)
        v=$(printf '%s' "$v" | sed -E "s#@(localhost|127\.0\.0\.1):[0-9]+#@${servico}-sandbox:5432#")
        v=$(sem_ssl "$v") ;;
      DATABASE_URL_MOTOR)
        v=$(sem_ssl "$v") ;;
    esac

    # ⚠️ Bloco literal (`|-`) e indentacao fixa: um segredo com `:` ou `#`
    # quebraria o YAML se fosse escrito na mesma linha, e o erro apareceria
    # como "campo desconhecido" -- longe da causa.
    corpo="$corpo
  $k: |-
    $v"
  done

  if [ -n "$faltando" ]; then
    echo "  $proj: ⚠️ AUSENTES no .env:$faltando"
  fi
  if [ -n "$vazias" ]; then
    # Informativo, nao alarme: sao funcionalidades declaradas e nao ligadas.
    echo "  $proj: (declaradas vazias:$vazias )"
  fi

  if printf '%s\n' "$corpo" | kubectl apply -f - >/dev/null 2>&1; then
    n=$(kubectl get secret "$nome" -n "$ns" -o jsonpath='{.data}' 2>/dev/null | grep -o '":"' | wc -l)
    echo "  $proj: secret '$nome' com $n chave(s)"
  else
    echo "  $proj: ERRO ao aplicar o secret"
    falhas=$((falhas+1))
  fi
done <<< "$LISTA"

exit "$falhas"

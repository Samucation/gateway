#!/usr/bin/env bash
# ===========================================================================
# Cria os Secrets de producao no k3s a partir dos `.env` dos projetos.
#
#     bash criar-segredos.sh                  # todos
#     bash criar-segredos.sh sigma-financeiro # so um
# ===========================================================================
#
# ⚠️ O SECRET LEVA O `.env` INTEIRO, e nao uma lista escolhida a mao.
#
# 🐞 A primeira versao tinha, por projeto, uma lista das chaves que os
# manifestos citam em `secretKeyRef`. Parecia certo e estava errado pela
# metade: os manifestos usam `envFrom: secretRef`, que injeta TUDO o que
# estiver no Secret -- exatamente como o `env_file` do docker-compose fazia.
#
# O estrago apareceu em producao, depois da virada, e nao como erro de
# configuracao:
#
#   [thumbnails] sigma-midia falhou: MIDIA_BASE_URL/MIDIA_API_KEY nao
#   configurados
#
# ...e a tela dizia "Arquivo nao e uma imagem JPEG, PNG ou WebP valida". O
# arquivo estava perfeito.
#
# Pior: a mesma lacuna tinha deixado de fora VINTE E NOVE variaveis do urupix,
# entre elas `MP_ACCESS_TOKEN`, `MP_WEBHOOK_SECRET`, `WOOVI_APP_ID`,
# `SIGMA_CLIENT_SECRET`, `AUTH_GOOGLE_*` e as `VAPID_*`. Ou seja: credencial
# de PAGAMENTO, login e notificacao. Nada disso deu erro na partida -- o app
# subiu, respondeu 200, e so falharia na hora de cobrar.
#
# A regra passa a ser a mesma do compose: o que esta no `.env` vai para o
# Secret. Ausencia de chave deixa de ser uma decisao minha.
#
# ---------------------------------------------------------------------------
# ⚠️ NENHUM VALOR APARECE NA TELA NEM VAI PARA ARQUIVO.
# ---------------------------------------------------------------------------
# O YAML e entregue ao `kubectl` pela ENTRADA. Como argumento de linha de
# comando, cada segredo apareceria em `ps` para qualquer usuario da maquina.
set -uo pipefail

REPOS=/mnt/e/Desenvolvimento/Dev/Workspace
alvo="${1:-}"
falhas=0

# projeto | namespace | nome-do-secret | servico-do-banco | chaves-extras
#
# As "extras" sao as que o manifesto exige e o `.env` NAO tem, porque no
# compose elas vinham de um padrao embutido ou eram montadas na hora.
LISTA=$(cat <<'FIM'
sigma-financeiro|sigma-financeiro|sigma-financeiro-secrets|sigma-db|POSTGRES_PASSWORD
live-flow|urupix|urupix-secrets|urupix-postgres|POSTGRES_PASSWORD
sprinklegames-portal|sprinklegames|sprinklegames-secrets|sprinklegames-postgres|POSTGRES_PASSWORD
opuschat|opuschat|opuschat-secrets|opuschat-postgres|POSTGRES_PASSWORD PLATFORM_ADMIN_TOTP
cafe-mobile-erp|plataforma|plataforma-secrets|plataforma-postgres|POSTGRES_PASSWORD PLATFORM_ADMIN_TOTP
central-ia|central-ia|central-ia-secrets|central-postgres-motor|DATABASE_URL_MOTOR DATABASE_URL_PORTAL MOTOR_SEGREDO
sigma-midia|sigma-midia|sigma-midia-secrets|sigma-midia-postgres|MC_HOST_MINIO MIDIA_DB_SENHA MINIO_ROOT_PASSWORD MINIO_ROOT_USER
system-api|veltrixa|veltrixa-secrets|veltrixa-postgres|KEYCLOAK_ADMIN_USER KEYCLOAK_SEED_ADMIN_PASSWORD
FIM
)

# ---------------------------------------------------------------------------
# O COFRE — o que nao vem de lugar nenhum e precisa existir
# ---------------------------------------------------------------------------
# ⚠️ Valor ESTAVEL entre execucoes: sortear de novo trocaria a senha embaixo de
# um Postgres que ja tem dados, e o app pararia de conectar sem nada ter
# mudado no codigo.
COFRE=/var/lib/prd-segredos
mkdir -p "$COFRE" && chmod 700 "$COFRE"

sortear_e_guardar() {
  local proj="$1" chave="$2" arq="$COFRE/$proj.env" valor
  if [ -f "$arq" ]; then
    valor=$(grep -m1 -E "^${chave}=" "$arq" 2>/dev/null) || valor=""
    if [ -n "$valor" ]; then printf '%s' "${valor#*=}"; return 0; fi
  fi
  valor=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
  printf '%s=%s\n' "$chave" "$valor" >> "$arq"
  chmod 600 "$arq"
  printf '%s' "$valor"
}

# ---------------------------------------------------------------------------
# 🐞 `?sslmode=disable` — sem isso o app nao conecta, e o erro culpa o servidor
# ---------------------------------------------------------------------------
#     Server does not support SSL, but it was required (default configuration)
#
# O driver de Postgres do Dart exige TLS por padrao; o Postgres do cluster nao
# tem TLS, e nao precisa -- o trafego nao sai da rede do cluster. Quem
# resolvia isso era o compose, montando a URL com o parametro embutido.
sem_ssl() {
  case "$1" in
    *sslmode=*) printf '%s' "$1" ;;
    *\?*)       printf '%s&sslmode=disable' "$1" ;;
    *)          printf '%s?sslmode=disable' "$1" ;;
  esac
}

# Le UMA variavel do .env sem executar o arquivo.
#
# ⚠️ `source` seria mais curto e perigoso: um `.env` com `$(...)` ou crase
# executaria comando como root.
ler_env() {
  local arquivo="$1" chave="$2" linha
  linha=$(grep -m1 -E "^[[:space:]]*${chave}=" "$arquivo" 2>/dev/null) || return 1
  linha="${linha#*=}"
  # 🐞 O CR vem primeiro: os `.env` sao CRLF, e sem tirar o `\r` a retirada de
  # aspas nao acha aspa nenhuma. Ja fez a aspa entrar DENTRO do nome do banco
  # (`database "liveflow%22"`), com o Prisma reclamando de identificador nao
  # terminado -- mensagem que nao aponta para CRLF em lugar nenhum.
  linha="${linha%$'\r'}"
  linha="${linha%\"}"; linha="${linha#\"}"
  linha="${linha%\'}"; linha="${linha#\'}"
  printf '%s' "$linha"
}

# Reescreve o endereco do banco: `localhost` de dentro de um Pod e o PROPRIO
# Pod, e a conexao seria recusada.
ajustar_url() {
  local valor="$1" servico="$2" chave="$3"
  case "$chave" in
    DATABASE_URL)
      valor=$(printf '%s' "$valor" | sed -E "s#@(localhost|127\.0\.0\.1):[0-9]+#@${servico}:5432#") ;;
    DATABASE_URL_SANDBOX)
      valor=$(printf '%s' "$valor" | sed -E "s#@(localhost|127\.0\.0\.1):[0-9]+#@${servico}-sandbox:5432#") ;;
    REDIS_URL)
      # O mesmo problema, outro servico: o Redis do cluster tem nome proprio.
      valor=$(printf '%s' "$valor" | sed -E "s#(localhost|127\.0\.0\.1):[0-9]+#${servico%%-postgres}-redis:6379#") ;;
  esac
  case "$chave" in
    DATABASE_URL|DATABASE_URL_SANDBOX|DATABASE_URL_MOTOR|DATABASE_URL_PORTAL)
      valor=$(sem_ssl "$valor") ;;
  esac
  printf '%s' "$valor"
}

# As que o manifesto pede e o `.env` nao tem.
derivar() {
  local proj="$1" k="$2" env_arq="$3" v="" senha u w
  case "$k" in
    POSTGRES_PASSWORD)
      # ⚠️ Nao existe no `.env` e nem deveria: na estacao o Postgres ja estava
      # criado; no cluster ele NASCE junto e precisa saber que senha atribuir.
      # Inventar uma daria banco de pe e app que nunca conecta.
      local url; url=$(ler_env "$env_arq" DATABASE_URL) || url=""
      local resto="${url#*://}"; local cred="${resto%%@*}"; v="${cred#*:}" ;;
    DATABASE_URL_MOTOR)
      senha=$(ler_env "$env_arq" POSTGRES_PASSWORD) || senha=""
      [ -n "$senha" ] && v=$(sem_ssl "postgresql://central:${senha}@central-postgres-motor:5432/central") ;;
    DATABASE_URL_PORTAL)
      senha=$(ler_env "$env_arq" POSTGRES_PASSWORD) || senha=""
      [ -n "$senha" ] && v=$(sem_ssl "postgresql://central:${senha}@central-postgres-portal:5432/central_portal") ;;
    MOTOR_SEGREDO)
      # A chave com que o PORTAL fala com o MOTOR: os dois leem a mesma. Cada
      # lado com a sua daria 401, e o sintoma seria "a IA nao responde".
      v=$(ler_env "$env_arq" MOTOR_SEGREDO) || v=""
      [ -z "$v" ] && v=$(sortear_e_guardar "$proj" MOTOR_SEGREDO) ;;
    KEYCLOAK_ADMIN_USER)          v=$(ler_env "$env_arq" KEYCLOAK_ADMIN) || v="" ;;
    KEYCLOAK_SEED_ADMIN_PASSWORD) v=$(ler_env "$env_arq" KEYCLOAK_ADMIN_PASSWORD) || v="" ;;
    MINIO_ROOT_USER)
      v=$(ler_env "$env_arq" MIDIA_S3_CHAVE) || v=""
      [ -z "$v" ] && v=$(sortear_e_guardar "$proj" MINIO_ROOT_USER) ;;
    MINIO_ROOT_PASSWORD)
      v=$(ler_env "$env_arq" MIDIA_S3_SEGREDO) || v=""
      [ -z "$v" ] && v=$(sortear_e_guardar "$proj" MINIO_ROOT_PASSWORD) ;;
    MIDIA_DB_SENHA)
      # 🔴 O `.env` nao define, e o compose cai no padrao `midia-local` -- a
      # senha de EXEMPLO que esta no repositorio. Nao se copia isso: sorteia.
      v=$(sortear_e_guardar "$proj" MIDIA_DB_SENHA) ;;
    MC_HOST_MINIO)
      u=$(ler_env "$env_arq" MIDIA_S3_CHAVE)   || u=""
      [ -z "$u" ] && u=$(sortear_e_guardar "$proj" MINIO_ROOT_USER)
      w=$(ler_env "$env_arq" MIDIA_S3_SEGREDO) || w=""
      [ -z "$w" ] && w=$(sortear_e_guardar "$proj" MINIO_ROOT_PASSWORD)
      v="http://${u}:${w}@sigma-midia-minio:9000" ;;
    PLATFORM_ADMIN_TOTP)
      # Opcional de verdade: o compose declara `${PLATFORM_ADMIN_TOTP:-}`.
      v="" ;;
  esac
  printf '%s' "$v"
}

while IFS='|' read -r proj ns nome servico extras <&3; do
  [ -n "$proj" ] || continue
  [ -z "$alvo" ] || [ "$alvo" = "$proj" ] || continue

  env_arq="$REPOS/$proj/.env"
  if [ ! -f "$env_arq" ]; then
    echo "  $proj: SEM .env em $env_arq"; falhas=$((falhas+1)); continue
  fi

  kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns" >/dev/null 2>&1

  corpo="apiVersion: v1
kind: Secret
metadata:
  name: $nome
  namespace: $ns
type: Opaque
stringData:"

  n=0
  # ---- primeiro, TUDO o que esta no `.env` --------------------------------
  for k in $(grep -oE "^[A-Z][A-Z0-9_]*" "$env_arq" 2>/dev/null | sort -u); do
    v=$(ler_env "$env_arq" "$k") || v=""
    v=$(ajustar_url "$v" "$servico" "$k")
    # Bloco literal: um valor com `:` ou `#` na mesma linha quebraria o YAML, e
    # o erro apareceria como "campo desconhecido" -- longe da causa.
    corpo="$corpo
  $k: |-
    $v"
    n=$((n+1))
  done

  # ---- depois, as que o manifesto exige e o `.env` nao tem ----------------
  for k in $extras; do
    grep -qE "^[[:space:]]*${k}=" "$env_arq" 2>/dev/null && continue
    v=$(derivar "$proj" "$k" "$env_arq")
    corpo="$corpo
  $k: |-
    $v"
    n=$((n+1))
  done

  if printf '%s\n' "$corpo" | kubectl apply -f - >/dev/null 2>&1; then
    echo "  $proj: '$nome' com $n chave(s)"
  else
    echo "  $proj: ERRO ao aplicar o secret"; falhas=$((falhas+1))
  fi
done 3<<< "$LISTA"

exit "$falhas"

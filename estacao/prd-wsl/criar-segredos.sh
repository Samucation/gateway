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
FIM
)

# Le UMA variavel do .env sem executar o arquivo.
#
# ⚠️ `source` seria mais curto e perigoso: um `.env` com `$(...)` ou crase
# executaria comando com o usuario que roda isto -- que aqui e o root.
ler_env() {
  local arquivo="$1" chave="$2" linha
  linha=$(grep -m1 -E "^[[:space:]]*${chave}=" "$arquivo" 2>/dev/null) || return 1
  linha="${linha#*=}"
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
  for k in $chaves; do
    v=$(ler_env "$env_arq" "$k") || v=""

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

    if [ -z "$v" ]; then faltando="$faltando $k"; continue; fi

    # ⚠️ A reescrita do host do banco. `localhost`/`127.0.0.1` viram o Service.
    case "$k" in
      DATABASE_URL)
        v=$(printf '%s' "$v" | sed -E "s#@(localhost|127\.0\.0\.1):[0-9]+#@${servico}:5432#") ;;
      DATABASE_URL_SANDBOX)
        v=$(printf '%s' "$v" | sed -E "s#@(localhost|127\.0\.0\.1):[0-9]+#@${servico}-sandbox:5432#") ;;
    esac

    # ⚠️ Bloco literal (`|-`) e indentacao fixa: um segredo com `:` ou `#`
    # quebraria o YAML se fosse escrito na mesma linha, e o erro apareceria
    # como "campo desconhecido" -- longe da causa.
    corpo="$corpo
  $k: |-
    $v"
  done

  if [ -n "$faltando" ]; then
    echo "  $proj: ⚠️ faltam no .env:$faltando"
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

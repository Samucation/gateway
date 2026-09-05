#!/usr/bin/env bash
# Sobe a producao EM ONDAS, em vez de deixar tudo brigar de uma vez.
#
#     wsl -d prd -- bash /mnt/e/.../prd-wsl/partida-escalonada.sh
#
# ---------------------------------------------------------------------------
# Por que escalonar
# ---------------------------------------------------------------------------
# Depois que o cadastro do containerd foi recriado, TODAS as imagens precisam
# ser baixadas de novo. Os ~90 Pods pedem ao mesmo tempo, e em 04/09/2026 a
# maquina virtual do WSL foi derrubada inteira no meio disso:
#
#   "The virtual machine or container was forcefully exited"
#
# Nao e falta de memoria no Windows (havia 39 GB livres): e o PICO dentro do
# teto de 40 GB da distro, com dezenas de contêineres partindo juntos.
#
# ---------------------------------------------------------------------------
# A ORDEM NAO E ARBITRARIA
# ---------------------------------------------------------------------------
#   1. registro   -- fonte de TODAS as nossas imagens. Sem ele, todo o resto
#                    fica em ImagePullBackOff, o que parece um problema em
#                    cada Pod e e um so.
#   2. bancos     -- as aplicacoes reiniciam em laco sem eles.
#   3. aplicacoes -- por ultimo, uma leva por vez.
#
# ⚠️ As replicas originais sao GUARDADAS antes de zerar. Sem isso, restaurar
# vira chute: um servico que rodava com 2 replicas volta com 1 e ninguem nota
# ate a primeira hora de pico.
set -uo pipefail

GUARDA=/var/lib/rancher/replicas-antes-da-partida.txt
ONDA_BANCOS="sonarqube veltrixa quatrosaas cartorio central-ia sigma-midia plataforma"

# 🐞 A LISTA ACIMA NAO COBRE TUDO QUE O `zerar_tudo_menos` DERRUBA.
#
# `zerar_tudo_menos registro` zera TODOS os namespaces do arquivo de guarda,
# mas o laco de restauracao so percorre $ONDA_BANCOS. Em 04/09/2026 sobraram
# em replicas=0, sem nada apontando o motivo:
#
#     urupix   opuschat   sigma-financeiro   sprinklegames   gateway
#
# ⚠️ `gateway` e o Kong: zera-lo tira a ENTRADA de tudo do ar.
#
# Lista escrita a mao apodrece calada -- namespace novo entraria no `zerar` e
# nunca no `restaurar`. Por isso a ultima onda e derivada do PROPRIO arquivo de
# guarda (preenchida depois de `anotar_replicas`), e nao digitada aqui.
ONDA_RESTO=""

anotar_replicas() {
  echo "== guardando as replicas atuais em $GUARDA =="
  # ⚠️ So grava se ainda nao existir. Rodar o script duas vezes com tudo
  # zerado sobrescreveria o arquivo com zeros -- e af a restauracao "funciona"
  # deixando tudo desligado.
  if [ -s "$GUARDA" ]; then
    echo "  ja existe ($(wc -l < "$GUARDA") linhas) -- mantendo o original"
    return
  fi
  kubectl get deploy,statefulset -A \
    -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' \
    2>/dev/null > "$GUARDA"
  echo "  $(wc -l < "$GUARDA") objeto(s) anotado(s)"
}

zerar_tudo_menos() {
  local manter="$1"
  echo "== zerando tudo, exceto: $manter =="
  while read -r kind ns nome _; do
    [ -z "${nome:-}" ] && continue
    case " $manter " in *" $ns "*) continue;; esac
    kubectl -n "$ns" scale "$kind" "$nome" --replicas=0 >/dev/null 2>&1
  done < "$GUARDA"
  echo "  feito"
}

restaurar() {
  local alvo="$1"
  echo "== restaurando: $alvo =="
  while read -r kind ns nome rep; do
    [ -z "${rep:-}" ] && continue
    case " $alvo " in *" $ns "*) ;; *) continue;; esac
    kubectl -n "$ns" scale "$kind" "$nome" --replicas="$rep" >/dev/null 2>&1
    echo "  $ns/$nome -> $rep"
  done < "$GUARDA"
}

esperar_registro() {
  echo "== esperando o registro atender (ate 300s) =="
  for i in $(seq 1 100); do
    cod=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:32000/v2/ 2>/dev/null)
    if [ "$cod" = "200" ]; then
      echo "  ✅ registro de pe na tentativa $i"
      curl -s --max-time 10 http://localhost:32000/v2/_catalog 2>/dev/null | head -c 300
      echo
      return 0
    fi
    [ $((i % 10)) = 0 ] && echo "  ainda nao ($cod), tentativa $i"
    sleep 3
  done
  echo "  ❌ o registro nao subiu"
  return 1
}

esperar_prontos() {
  local ns="$1" limite="${2:-60}"
  for i in $(seq 1 "$limite"); do
    total=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | wc -l)
    prontos=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '{split($2,p,"/"); if (p[1]==p[2] && p[1]>0) c++} END {print c+0}')
    [ "$total" -gt 0 ] && [ "$prontos" = "$total" ] && { echo "  ✅ $ns: $prontos/$total"; return 0; }
    sleep 5
  done
  echo "  ⚠️ $ns: $prontos/$total prontos (seguindo mesmo assim)"
}

# ---------------------------------------------------------------------------
kubectl get nodes --no-headers 2>/dev/null || { echo "❌ api fora do ar"; exit 1; }

anotar_replicas
zerar_tudo_menos "registro"

# 🐞 EM 04/09/2026 ESTE `exit 1` DEIXOU MEIA PRODUCAO ZERADA.
#
# O registro nao atendia por causa de uma regra de NAT morta na 32000 (Pod
# antigo), e nao por defeito dele. O script ja tinha zerado tudo, entao saiu
# aqui e nunca restaurou -- deixando os namespaces em replicas=0 sem nada no
# log que ligasse uma coisa a outra.
#
# Agora ele TENTA CONSERTAR a causa conhecida antes de desistir.
if ! esperar_registro; then
  echo "== o registro nao atendeu: limpando hostPort morto e tentando de novo =="
  bash "$(dirname "$0")/limpar-hostport-morto.sh" || true
  esperar_registro || {
    echo "❌ o registro continua fora. NAO vou seguir com tudo zerado --"
    echo "   restaurando as replicas originais antes de sair."
    for ns in $(awk '{print $2}' "$GUARDA" | sort -u); do restaurar "$ns"; done
    exit 1
  }
fi

for ns in $ONDA_BANCOS; do
  restaurar "$ns"
  echo "  aguardando $ns assentar..."
  esperar_prontos "$ns" 40
done

# Ultima onda: TODO o resto que foi zerado e ainda nao voltou -- urupix,
# opuschat, sigma-financeiro, sprinklegames e o gateway (Kong). Sai do proprio
# arquivo de guarda, entao namespace novo entra sozinho.
ONDA_RESTO=$(awk '{print $2}' "$GUARDA" 2>/dev/null | sort -u | tr '\n' ' ')
for ns in $ONDA_RESTO; do
  case " $ONDA_BANCOS " in *" $ns "*) continue;; esac
  restaurar "$ns"
  echo "  aguardando $ns assentar..."
  esperar_prontos "$ns" 40
done

# 🐞 CONFERE QUE NAO SOBROU NINGUEM EM ZERO.
#
# Este script ja saiu no `exit 1` do `esperar_registro` deixando meia producao
# zerada -- e o operador so descobriu horas depois, porque Pod que nao existe
# nao aparece em `get pods` para acusar nada.
echo
echo "== quem ficou em replicas=0 =="
sobrou=$(kubectl get deploy,statefulset -A \
  -o jsonpath='{range .items[?(@.spec.replicas==0)]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)
if [ -n "$sobrou" ]; then
  echo "$sobrou" | sed 's/^/  ⚠️ /'
else
  echo "  ✅ ninguem"
fi

echo
echo "== estado final =="
kubectl get pods -A --no-headers 2>/dev/null | awk '{split($3,p,"/"); if (p[1]==p[2] && p[1]>0) ok++; else nok++} END {print "  prontos: " ok+0 "   nao prontos: " nok+0}'

#!/usr/bin/env bash
# O Mercado Pago está FUNCIONAL em produção?
#
# ⚠️ SÓ LEITURA, e sem exercitar a credencial real. Criar cobrança de teste em
# produção violaria a regra de ouro (teste só em sandbox); e até uma chamada
# "inofensiva" com o token de produção é uso de credencial de dinheiro real, que
# não se faz sem pedir.
#
# O que dá para provar sem tocar em nada:
#
#   1. o Pod ALCANÇA a API do Mercado Pago (caminho de rede aberto);
#   2. o HISTÓRICO mostra cobranças reais que funcionaram — evidência melhor que
#      qualquer teste sintético, porque é o fluxo de verdade que já rodou.
set -uo pipefail
NS=sigma-financeiro
DB=${POD_DB:-sigma-db-0}

le() { kubectl exec -n "$NS" "$DB" -- psql -U sigma -d sigma_financeiro -tAc "$1" 2>/dev/null | tr -d '\r'; }

echo "== 1. o Pod alcança a API do Mercado Pago? =="
pod=$(kubectl get pods -n "$NS" -l app=sigma-financeiro --no-headers 2>/dev/null | grep ' Running ' | tail -1 | awk '{print $1}')
c=$(kubectl run mp$RANDOM -n "$NS" --rm -i --restart=Never --image=curlimages/curl:8.10.1 --quiet -- \
    -s -o /dev/null -w '%{http_code}' --max-time 20 https://api.mercadopago.com/users/me 2>/dev/null | tr -d '\r')
# 401 é a resposta CERTA aqui: chegamos na API e ela pediu credencial — que não
# foi enviada de propósito. 000 seria rede fechada.
case "${c:-000}" in
  401|403) echo "  https://api.mercadopago.com -> $c  ✅ alcançável (401 = pediu credencial, como esperado)" ;;
  000)     echo "  https://api.mercadopago.com -> sem resposta  ❌ o Pod não sai para a internet" ;;
  *)       echo "  https://api.mercadopago.com -> $c" ;;
esac

echo
echo "== 2. o histórico de cobranças pelo Mercado Pago =="
tab=$(le "SELECT table_name FROM information_schema.tables
          WHERE table_schema='public' AND table_name ILIKE '%cobranc%' LIMIT 1")
if [ -z "$tab" ]; then
  echo "  (não achei a tabela de cobranças neste esquema)"
  exit 0
fi
echo "  tabela: $tab"

le "SELECT '  ' || COALESCE(provedor,'?') || ' | ' || COALESCE(status,'?') || ' | ' || count(*) || ' cobranca(s)'
    FROM \"$tab\" GROUP BY provedor, status ORDER BY count(*) DESC LIMIT 10"

echo
echo "  == a mais recente que deu certo =="
le "SELECT '  ultima paga: ' || COALESCE(max(\"atualizadoEm\")::text, '(nenhuma)')
    FROM \"$tab\" WHERE provedor = 'MERCADO_PAGO' AND status IN ('PAGA','PAGO','APPROVED','approved')"

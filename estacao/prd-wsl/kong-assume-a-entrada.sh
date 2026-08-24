#!/usr/bin/env bash
# ===========================================================================
# Faz o KONG ser a entrada da produção, no lugar do Traefik.
#
#     bash kong-assume-a-entrada.sh            # assume
#     bash kong-assume-a-entrada.sh --voltar   # devolve ao Traefik
#
# ---------------------------------------------------------------------------
# POR QUE MEXER NA PORTA 80 DA DISTRO, E NÃO NO `netsh`
# ---------------------------------------------------------------------------
# O caminho do tráfego é
#
#     cloudflared (Windows) -> 127.0.0.1:8050 -> portproxy -> <ip-da-distro>:80
#
# O certo seria apontar o `portproxy` para a 8050 da distro, onde o Kong tem
# `hostPort`. Só que `netsh interface portproxy` exige Administrador e, sem
# ele, FALHA EM SILÊNCIO: o comando volta 0 e a tabela continua igual.
#
# Então a troca é feita do lado de dentro, onde não é preciso pedir nada a
# ninguém: quem ocupa a porta 80 da distro passa a ser o Kong. O Traefik não
# sai de cena — continua roteando os Ingress, agora chamado pelo Kong.
#
#     antes:  :80 = svclb do Traefik  -> Ingress -> Service
#     depois: :80 = Kong (hostPort)   -> Service, e o que ele não declara
#                                        segue para o Traefik pelo ClusterIP
#
# ⚠️ O script CONFERE os 16 hosts depois de trocar e DESFAZ sozinho se algum
# deixar de responder como respondia. Ninguém está acordado para socorrer.
# ===========================================================================
set -uo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

voltar() {
  echo "== devolvendo a entrada ao Traefik =="
  kubectl patch svc traefik -n kube-system -p '{"spec":{"type":"LoadBalancer"}}' >/dev/null
  kubectl patch deploy kong -n gateway --type=json \
    -p '[{"op":"remove","path":"/spec/template/spec/containers/0/ports/1"}]' >/dev/null 2>&1
  kubectl rollout status deploy/kong -n gateway --timeout=120s | tail -1 | sed 's/^/  /'
  sleep 5
  echo "  traefik: $(kubectl get svc traefik -n kube-system -o jsonpath='{.spec.type}')"
}

if [ "${1:-}" = "--voltar" ]; then voltar; exit 0; fi

echo "== 0. gravando a linha de base, com o Traefik ainda na entrada =="
# ⚠️ ANTES de trocar. Depois da troca, a porta 80 é o Kong — e comparar a porta
# 80 com a 8050 compararia o Kong com ele mesmo, passando sempre.
bash "$AQUI/conferir-kong.sh" --gravar-base | tail -3 | sed 's/^/  /'

echo "== 1. Kong passa a escutar tambem na 80 do no =="
# Uma segunda entrada de porta para o MESMO containerPort. O Kong escuta 8000
# lá dentro; o nó publica 8050 (histórico) e 80 (a que o portproxy usa hoje).
kubectl patch deploy kong -n gateway --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/ports/1","value":{"name":"proxy80","containerPort":8000,"hostPort":80}}]' >/dev/null

echo "== 2. Traefik solta a porta 80 do no =="
# `LoadBalancer` no k3s cria o DaemonSet `svclb-traefik`, que é quem prende a
# 80 e a 443 do nó. Virando `ClusterIP` o svclb some e a porta fica livre.
# O Service continua existindo com o mesmo nome e ClusterIP — que é como a
# rota de reserva do Kong chega nele.
kubectl patch svc traefik -n kube-system -p '{"spec":{"type":"ClusterIP"}}' >/dev/null

echo "== 3. esperando o Kong assumir =="
kubectl rollout status deploy/kong -n gateway --timeout=180s | tail -1 | sed 's/^/  /'

# O Pod pode estar pronto e a porta do nó ainda não estar publicada.
for i in $(seq 1 20); do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: urupix.com.br' http://127.0.0.1:80/ 2>/dev/null)
  [ "$c" = "200" ] && break
  sleep 3
done
echo "  urupix pela porta 80 do no: ${c:-000}"

echo
echo "== 4. conferindo os 16 hosts PELA PORTA 80 =="
# ⚠️ A conferência tem de ser pelo caminho REAL (a 80, que é para onde o
# portproxy manda), e não pela 8050 do Kong — senão ela prova o caminho que
# ninguém usa.
if bash "$AQUI/conferir-kong.sh" --pela-entrada; then
  echo
  echo "  ✅ o Kong e a entrada, e todos os hosts respondem como antes"
  exit 0
fi

echo
echo "  ❌ algo mudou de resposta. DESFAZENDO."
voltar
exit 1

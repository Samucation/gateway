#!/usr/bin/env bash
# Remove as regras de hostPort que apontam para Pod que nao existe mais.
#
#     wsl -d prd -u root -- bash /mnt/e/.../prd-wsl/limpar-hostport-morto.sh
#     wsl -d prd -u root -- bash .../limpar-hostport-morto.sh --so-conferir
#
# ---------------------------------------------------------------------------
# 🐞 O DEFEITO QUE ISTO CONSERTA (04/09/2026 -- producao inteira fora do ar)
# ---------------------------------------------------------------------------
# Quando a distro reinicia, o kubelet recria os sandboxes e o plugin `portmap`
# escreve uma cadeia CNI-DN-* nova para cada hostPort. A cadeia ANTIGA nem
# sempre e removida -- e ela continua em CNI-HOSTPORT-DNAT, ANTES da nova.
#
# Como o iptables atende a PRIMEIRA que casa, quem responde e a cadeia morta,
# que faz DNAT para o IP de um Pod que ja nao existe. O sintoma nao se parece
# nada com a causa:
#
#     curl localhost:32000/v2/   ->  "No route to host"
#
# ...com o Pod do registro `1/1 Running` e o registro atendendo 200 no IP dele.
#
# ⚠️ E o estrago se espalha: sem o registro em `localhost:32000`, TODA imagem
# nossa falha e o cluster inteiro vai a ImagePullBackOff. Parece um problema em
# cada aplicacao, e e uma regra de NAT sobrando.
#
# ⚠️ Pior: a `partida-escalonada.sh` zera tudo e espera o registro atender para
# restaurar. Com esta regra morta no caminho ela nunca restaura -- e sai
# deixando meia producao em `replicas=0`, sem Pod nenhum para acusar o motivo.
#
# `ss -lnt` NAO ajuda a enxergar isto: hostPort do k3s e DNAT, nao e socket em
# escuta. A porta some do `ss` mesmo funcionando. Quem mostra a verdade e a
# tabela `nat`.
set -uo pipefail

# O k3s nao instala iptables no PATH; ele traz o proprio em `aux/`.
IPT=/var/lib/rancher/k3s/data/current/bin/aux/iptables
[ -x "$IPT" ] || { echo "❌ nao achei o iptables do k3s em $IPT"; exit 1; }

SO_CONFERIR=0
[ "${1:-}" = "--so-conferir" ] && SO_CONFERIR=1

VIVOS=$(kubectl get pods -A -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' 2>/dev/null \
        | grep -v '^$' | sort -u)
if [ -z "$VIVOS" ]; then
  echo "❌ nao consegui listar os Pods -- sem isso eu nao sei o que esta morto."
  echo "   (apagar cadeia sem essa lista derrubaria hostPort que funciona)"
  exit 1
fi

MORTAS=""
while read -r linha; do
  [ -z "$linha" ] && continue
  cadeia=$(awk '{print $2}' <<<"$linha")
  destino=$(sed 's/.*--to-destination //' <<<"$linha" | awk '{print $1}')
  porta=$(sed 's/.*--dport //' <<<"$linha" | awk '{print $1}')
  ip=${destino%%:*}
  if grep -qx "$ip" <<<"$VIVOS"; then
    printf '  vivo    porta=%-6s -> %s\n' "$porta" "$destino"
  else
    printf '  MORTA   porta=%-6s -> %s   (%s)\n' "$porta" "$destino" "$cadeia"
    MORTAS="$MORTAS $cadeia"
  fi
done < <("$IPT" -t nat -S 2>/dev/null | grep -E '^-A CNI-DN-' | grep -- '-j DNAT')

if [ -z "${MORTAS// /}" ]; then
  echo "✅ nenhuma regra de hostPort apontando para Pod morto"
  exit 0
fi

if [ "$SO_CONFERIR" = 1 ]; then
  echo "⚠️ ha cadeia morta (rode sem --so-conferir para remover)"
  exit 1
fi

for cadeia in $MORTAS; do
  echo "== removendo $cadeia =="
  # Tira primeiro o desvio que leva ate ela; so depois esvazia e apaga. Na
  # ordem inversa o iptables recusa apagar cadeia ainda referenciada.
  while read -r regra; do
    [ -z "$regra" ] && continue
    eval "$IPT -t nat $regra" && echo "  desvio removido"
  done < <("$IPT" -t nat -S CNI-HOSTPORT-DNAT 2>/dev/null \
           | grep -- "-j $cadeia" | sed 's/^-A /-D /')
  "$IPT" -t nat -F "$cadeia" 2>/dev/null && "$IPT" -t nat -X "$cadeia" 2>/dev/null \
    && echo "  cadeia apagada"
done

# 🐞 CONFERE O EFEITO, e nao o pedido. Anunciar "limpei" sem medir devolveria
# exatamente o silencio que fez esta queda demorar horas para aparecer.
echo
echo "== conferindo o registro na porta de verdade =="
cod=$(curl -s -o /dev/null -m 10 -w '%{http_code}' http://localhost:32000/v2/ 2>/dev/null)
echo "  localhost:32000 -> $cod"
[ "$cod" = "200" ] || { echo "  ⚠️ o registro ainda nao atende"; exit 1; }
echo "  ✅ registro de pe"

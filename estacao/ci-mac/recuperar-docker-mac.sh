#!/bin/sh
# Reinicia o OrbStack quando o daemon do Mac trava.
#
# ⚠️ Sintoma: `docker ps` PENDURA (nao devolve erro, nao devolve nada). Um
# conteiner preso enrosca o daemon inteiro, e dali em diante toda build no
# agente Mac fica em silencio -- o que se le' como "build lenta".
MAC=192.168.15.25
U=samuelferreiraduarte
CHAVE=/var/lib/jenkins/.ssh/ci-mac
SSH="sudo -u jenkins ssh -i $CHAVE -o BatchMode=yes -o ConnectTimeout=15 -o UserKnownHostsFile=/var/lib/jenkins/.ssh/known_hosts $U@$MAC"

echo "== matando processos docker pendurados =="
$SSH 'pkill -f "docker (run|ps|image|info)" 2>/dev/null; echo "  ok"'

echo
echo "== reiniciando o OrbStack =="
$SSH 'osascript -e "quit app \"OrbStack\"" 2>/dev/null; echo "  pedido de saida enviado"'
sleep 8
$SSH 'pkill -9 -f OrbStack 2>/dev/null; echo "  restos removidos"'
sleep 3
$SSH 'open -a OrbStack; echo "  reaberto"'

echo
echo "== esperando o daemon responder (ate 90s) =="
i=0
while [ $i -lt 18 ]; do
  R=$($SSH '/Users/samuelferreiraduarte/.orbstack/bin/docker version --format "{{.Server.Version}}"' 2>/dev/null | tr -d '\r\n ')
  if [ -n "$R" ]; then echo "  ✅ daemon respondeu: $R"; break; fi
  sleep 5; i=$((i+1))
done
[ -n "$R" ] || echo "  ❌ daemon ainda mudo"

echo
echo "== containers agora =="
$SSH '/Users/samuelferreiraduarte/.orbstack/bin/docker ps -a --format "  {{.Names}} | {{.Status}}"' 2>&1 | head -6

#!/bin/sh
# ===========================================================================
# `--net host` FUNCIONA NO MAC?
# ===========================================================================
# Os estagios de teste do cartorio sobem um Postgres em conteiner e o
# alcancam por `localhost` -- e' isso que `--net host` viabiliza na distro.
#
# ⚠️ No macOS o Docker roda dentro de uma VM Linux, entao "host" NAO e' o
# Mac: historicamente `--network host` no Docker Desktop nao expunha a porta
# ao Mac, e o teste falhava com "connection refused" em algo que funciona no
# Linux. O OrbStack anuncia suporte de verdade -- mas anuncio nao e' medida.
#
# Se nao funcionar, o caminho e' publicar porta (`-p`) e entregar o endereco
# por variavel de ambiente, que e' o que a propria esteira ja' faz em outros
# projetos.
MAC=192.168.15.25
U=samuelferreiraduarte
CHAVE=/var/lib/jenkins/.ssh/ci-mac
SSH="sudo -u jenkins ssh -i $CHAVE -o BatchMode=yes -o ConnectTimeout=20 -o UserKnownHostsFile=/var/lib/jenkins/.ssh/known_hosts $U@$MAC"
P='export PATH=$HOME/.orbstack/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'

echo "== 1. Postgres com --net host, alcancado por localhost =="
$SSH "$P
  docker rm -f zz-pg >/dev/null 2>&1
  docker run -d --name zz-pg --net host -e POSTGRES_PASSWORD=teste postgres:16-alpine >/dev/null 2>&1 \
    && echo '  container subiu' || echo '  FALHOU ao subir'
  for i in \$(seq 1 20); do
    if docker exec zz-pg pg_isready -h 127.0.0.1 >/dev/null 2>&1; then echo \"  pg_isready DENTRO: ok (tentativa \$i)\"; break; fi
    sleep 2
  done
  # A prova que importa: do MAC (fora do conteiner), a porta 5432 responde?
  if nc -z -w 3 127.0.0.1 5432 2>/dev/null; then
    echo '  ✅ o Mac alcanca 127.0.0.1:5432 -- --net host FUNCIONA'
  else
    echo '  ❌ o Mac NAO alcanca 127.0.0.1:5432 -- --net host nao expoe ao Mac'
  fi
  docker rm -f zz-pg >/dev/null 2>&1"

echo
echo "== 2. alternativa: publicar porta com -p =="
$SSH "$P
  docker rm -f zz-pg2 >/dev/null 2>&1
  docker run -d --name zz-pg2 -p 55432:5432 -e POSTGRES_PASSWORD=teste postgres:16-alpine >/dev/null 2>&1
  for i in \$(seq 1 20); do
    nc -z -w 2 127.0.0.1 55432 2>/dev/null && break
    sleep 2
  done
  if nc -z -w 3 127.0.0.1 55432 2>/dev/null; then
    echo '  ✅ -p 55432:5432 funciona (caminho alternativo garantido)'
  else
    echo '  ❌ nem com -p'
  fi
  docker rm -f zz-pg2 >/dev/null 2>&1"

echo
echo "== 3. um conteiner alcanca outro por localhost com --net host? =="
# ⚠️ E' isto que o teste do Maven faz: ele roda DENTRO de um conteiner e
# procura o Postgres em localhost.
$SSH "$P
  docker rm -f zz-pg3 >/dev/null 2>&1
  docker run -d --name zz-pg3 --net host -e POSTGRES_PASSWORD=teste postgres:16-alpine >/dev/null 2>&1
  sleep 12
  R=\$(docker run --rm --net host alpine:3 sh -c 'apk add --no-cache netcat-openbsd >/dev/null 2>&1; nc -z -w 3 127.0.0.1 5432 && echo ALCANCA || echo NAO' 2>/dev/null | tail -1)
  echo \"  conteiner->conteiner por localhost: \$R\"
  docker rm -f zz-pg3 >/dev/null 2>&1"

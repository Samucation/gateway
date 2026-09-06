#!/bin/bash
# ===========================================================================
# PREPARA O MacBook (Apple Silicon) PARA SER AGENTE DE CI DO JENKINS.
#
#     Rode ESTE arquivo NO MAC:
#         bash preparar-mac.sh
#
# Ele NAO instala nada sozinho: confere, e diz o que falta. Instalar em
# maquina que nao e' minha, sem a pessoa olhando, e' como se perde confianca.
# ===========================================================================
#
# ---------------------------------------------------------------------------
# ⚠️ A ARMADILHA QUE DECIDE TUDO: ARQUITETURA
# ---------------------------------------------------------------------------
# O cluster k3s da estacao e' **amd64**. Este Mac e' **arm64**.
#
# Imagem construida nativamente aqui NAO RODA la'. E o pior: nao falha no
# build -- falha na hora de subir o Pod, com `exec format error`. Quebra
# calada, do tipo mais caro de achar.
#
# Por isso TODA construcao de imagem para a estacao tem de levar
# `--platform linux/amd64`, e por isso este script exige buildx com QEMU.
# ---------------------------------------------------------------------------
set -uo pipefail

falta=0
ok()    { printf '  \033[32mok\033[0m    %s\n' "$1"; }
falha() { printf '  \033[31mFALTA\033[0m %s\n' "$1"; falta=$((falta+1)); }
nota()  { printf '        %s\n' "$1"; }

echo "== 1. maquina =="
ARQ=$(uname -m)
echo "  arquitetura: $ARQ"
echo "  macOS......: $(sw_vers -productVersion 2>/dev/null || echo '?')"
echo "  nucleos....: $(sysctl -n hw.ncpu 2>/dev/null || echo '?')"
echo "  memoria....: $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) GB"
if [ "$ARQ" != "arm64" ]; then
  nota "⚠️ esperava arm64 (Apple Silicon). Siga assim mesmo, mas revise o plano."
fi

echo
echo "== 2. Java (o agente do Jenkins roda em Java) =="
# Jenkins 2.568 exige Java 17+; 21 e' o alvo confortavel.
if command -v java >/dev/null 2>&1; then
  V=$(java -version 2>&1 | head -1)
  ok "java presente -- $V"
  MAIOR=$(java -version 2>&1 | head -1 | sed -E 's/.*"([0-9]+).*/\1/')
  if [ "${MAIOR:-0}" -lt 17 ] 2>/dev/null; then
    falha "Java $MAIOR e' velho demais (o agente precisa de 17+)"
    nota  "instale:  brew install --cask temurin@21"
  fi
else
  falha "java ausente"
  nota  "instale:  brew install --cask temurin@21"
fi

echo
echo "== 3. git =="
command -v git >/dev/null 2>&1 && ok "git -- $(git --version)" || {
  falha "git ausente"; nota "instale:  xcode-select --install"; }

echo
echo "== 4. runtime de conteiner (OrbStack) =="
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "docker responde -- $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
    CTX=$(docker context show 2>/dev/null)
    nota "contexto: ${CTX:-?}"
  else
    falha "o comando docker existe mas o servidor NAO responde"
    nota  "abra o OrbStack e espere ele subir"
  fi
else
  falha "docker ausente"
  nota  "instale:  brew install --cask orbstack"
fi

echo
echo "== 5. buildx + emulacao amd64 (o item critico) =="
if docker buildx version >/dev/null 2>&1; then
  ok "buildx -- $(docker buildx version | head -1)"
  # A prova real nao e' "buildx existe": e' conseguir RODAR algo amd64.
  echo "  testando execucao amd64 emulada (pode demorar na 1a vez)..."
  if docker run --rm --platform linux/amd64 alpine:3 uname -m 2>/dev/null | grep -q x86_64; then
    ok "emulacao amd64 FUNCIONA (rodou x86_64 neste Mac)"
  else
    falha "nao consegui rodar conteiner amd64"
    nota  "no OrbStack a emulacao vem ligada; confira em Settings > Rosetta/emulation"
  fi
else
  falha "buildx ausente"
fi

echo
echo "== 6. login remoto (o Jenkins conecta AQUI por SSH) =="
# ⚠️ O Jenkins fica preso em 127.0.0.1 na estacao. Quem inicia a conexao e'
# ELE, para ca'. Assim nao e' preciso expor o Jenkins na rede -- so' o sshd
# deste Mac, com chave.
if sudo -n systemsetup -getremotelogin 2>/dev/null | grep -qi on; then
  ok "Remote Login (sshd) LIGADO"
elif netstat -an 2>/dev/null | grep -q '\.22 .*LISTEN'; then
  ok "algo escutando na porta 22"
else
  falha "Remote Login desligado"
  nota  "ligue em: Ajustes > Geral > Compartilhamento > Login Remoto"
  nota  "ou:       sudo systemsetup -setremotelogin on"
fi

echo
echo "== 7. endereco deste Mac na rede (o Jenkins vai precisar) =="
for i in en0 en1; do
  IP=$(ipconfig getifaddr $i 2>/dev/null)
  [ -n "$IP" ] && echo "  $i: $IP"
done
echo "  nome: $(scutil --get LocalHostName 2>/dev/null).local"

echo
echo "== 8. pasta de trabalho do agente =="
RAIZ="$HOME/jenkins-agente"
if [ -d "$RAIZ" ]; then ok "$RAIZ ja existe"; else
  mkdir -p "$RAIZ" && ok "criei $RAIZ"
fi

echo
if [ "$falta" -eq 0 ]; then
  echo "✅ o Mac esta pronto para virar agente."
  echo "   Me passe o IP acima e eu crio o no' no Jenkins."
else
  echo "⚠️ faltam $falta item(ns) acima. Resolva e rode de novo."
  exit 1
fi

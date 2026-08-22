#!/bin/sh
# ===========================================================================
# Troca o endereco da VM de DHCP para FIXO, com REVERSAO AUTOMATICA armada.
#
#   sudo sh fixar-ip.sh
#
# ---------------------------------------------------------------------------
# ⚠️ POR QUE A REVERSAO EXISTE
# ---------------------------------------------------------------------------
# Esta VM roda PRODUCAO, e o unico acesso a ela e o SSH -- que passa pela mesma
# rede que este script esta mexendo. Um erro aqui nao da erro: da silencio. A
# maquina some, producao cai, e nao ha como entrar para desfazer.
#
# Entao, ANTES de aplicar, fica armado um gatilho: em 4 minutos, se ninguem
# tiver criado `/tmp/ip-confirmado`, a configuracao antiga volta sozinha.
#
# O `nohup` e essencial: o `netplan apply` DERRUBA a sessao SSH que o executou.
# Sem `nohup`, o gatilho morreria junto com a sessao -- justamente no cenario em
# que ele e necessario.
#
# ---------------------------------------------------------------------------
# ⚠️ ISTO NAO SUBSTITUI A RESERVA DE DHCP NO ROTEADOR
# ---------------------------------------------------------------------------
# Endereco fixo na maquina resolve metade: ela para de mudar sozinha. A outra
# metade e o roteador nao entregar o mesmo numero a outro aparelho. Sem reserva,
# um conflito de endereco continua possivel -- so ficou improvavel, porque
# `.240` esta fora da faixa que o roteador vem usando (conferido: de `.2` a
# `.60` ha quatro aparelhos, e de `.200` a `.254` nenhum).
#
# MAC desta VM, para cadastrar a reserva:  00:0c:29:81:18:ed
# ===========================================================================
set -e

ARQ=/etc/netplan/00-installer-config.yaml
BK=/etc/netplan/00-installer-config.yaml.antes-do-ip-fixo
NOVO=192.168.15.240

[ "$(id -u)" = "0" ] || { echo "precisa ser root"; exit 1; }

if [ ! -f "$BK" ]; then
    cp "$ARQ" "$BK"
    echo "  copia de seguranca em $BK"
fi

rm -f /tmp/ip-confirmado

# ⚠️ Gatilho armado ANTES de qualquer alteracao.
nohup sh -c "
    sleep 240
    if [ ! -f /tmp/ip-confirmado ]; then
        cp $BK $ARQ
        netplan apply
        echo 'revertido por falta de confirmacao' > /tmp/ip-revertido
    fi
" >/tmp/fixar-ip-gatilho.log 2>&1 &

echo "  reversao armada: volta em 4 min se /tmp/ip-confirmado nao existir"

cat > "$ARQ" <<'YAML'
# Endereco FIXO. Trocado de DHCP em 22/08/2026.
#
# 🐞 A VM mudou de endereco sozinha tres vezes: .54 -> .55 -> .56. Cada troca
# quebrou coisas que apontavam para o numero antigo, e nenhuma delas deu um erro
# util:
#
#   - o espelho de registro do cluster de homologacao parou de baixar imagem, com
#     sintoma `ImagePullBackOff` -- que faz procurar defeito na imagem;
#   - a guarda de deriva de tag passou a dizer que NADA estava rodando, que e
#     exatamente o alarme que ela existe para dar.
#
# ⚠️ `.240` foi escolhido por estar fora da faixa que o roteador vem usando: de
# `.2` a `.60` ha quatro aparelhos, e de `.200` a `.254` nenhum respondeu.
#
# ⚠️ Isto NAO substitui reserva de DHCP no roteador. Sem ela, o roteador ainda
# pode entregar `.240` a outro aparelho. MAC para cadastrar: 00:0c:29:81:18:ed
network:
  version: 2
  ethernets:
    ens33:
      match:
        macaddress: 00:0c:29:81:18:ed
      set-name: ens33
      dhcp4: false
      # IPv6 continua no automatico: o roteador anuncia um DNS por link-local
      # (fe80::...) que o resolvectl usa.
      dhcp6: true
      addresses:
        - 192.168.15.240/24
      routes:
        - to: default
          via: 192.168.15.1
      nameservers:
        addresses:
          - 192.168.15.1
          # ⚠️ Segundo servidor de proposito. Com so o roteador na lista, uma
          # reinicializacao dele deixa a VM sem resolver nome nenhum -- e o
          # sintoma vira "a esteira nao acha o registro", nao "o DNS caiu".
          - 1.1.1.1
YAML

chmod 600 "$ARQ"
echo "  configuracao escrita: $NOVO"

netplan apply
echo "  aplicado"

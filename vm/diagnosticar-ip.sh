#!/bin/sh
# Aplica o endereco fixo, REGISTRA o que aconteceu, e reverte em 90 segundos.
#
# ⚠️ Existe porque a primeira tentativa falhou em silencio: o `netplan apply`
# imprimiu sucesso, os links do Calico oscilaram (prova de que networkd
# reconfigurou) -- e o endereco continuou o do DHCP. Sem registro do estado
# logo apos o apply, so da para adivinhar.
set -e

ARQ=/etc/netplan/00-installer-config.yaml
BK=/etc/netplan/00-installer-config.yaml.antes-do-ip-fixo
LOG=/tmp/diag-ip.txt

: > "$LOG"
echo "== antes ==" >> "$LOG"
ip -4 -o addr show ens33 >> "$LOG" 2>&1

# Reversao curta: 90s bastam para o diagnostico.
nohup sh -c "
    sleep 90
    cp $BK $ARQ
    netplan apply
    echo revertido >> $LOG
" >/dev/null 2>&1 &

sed -n '/^network:/,/^          - 1.1.1.1/p' /tmp/fixar-ip.sh > "$ARQ"
chmod 600 "$ARQ"

netplan apply >> "$LOG" 2>&1
echo "== apply terminou ==" >> "$LOG"

sleep 8
echo "== 8s depois ==" >> "$LOG"
ip -4 -o addr show ens33 >> "$LOG" 2>&1
networkctl status ens33 2>&1 | head -20 >> "$LOG"

echo "== o que networkd gerou ==" >> "$LOG"
ls -1 /run/systemd/network/ >> "$LOG" 2>&1
cat /run/systemd/network/*ens33*.network >> "$LOG" 2>&1

echo "== journal ==" >> "$LOG"
journalctl -u systemd-networkd --since "-2min" --no-pager 2>&1 | grep -i "ens33" | tail -12 >> "$LOG"

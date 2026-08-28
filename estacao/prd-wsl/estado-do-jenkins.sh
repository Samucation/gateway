#!/usr/bin/env bash
# Fotografa o estado do Jenkins e do caminho de acesso ate ele, na distro `prd`.
#
# Existe porque em 28/08/2026 o Jenkins estava PERFEITAMENTE no ar (systemd,
# :8080, respondendo 200) e mesmo assim "nao dava para acessar": o que tinha
# morrido era a ROTA, nao o servico. O acesso externo vinha de um tunel PROPRIO
# (`serverhomol`) que rodava na VM, desligada em 24/08 -- e a rota nunca foi
# refeita nesta estacao.
#
# ⚠️ Servico de pe nao e evidencia de servico alcancavel. Este script mede as
# duas coisas separadas, porque foi a confusao entre elas que custou o tempo.
set -uo pipefail

echo "== 1. o servico =="
printf '  systemd: '; systemctl is-active jenkins 2>/dev/null || echo inativo
printf '  porta:   '; ss -ltnp 2>/dev/null | grep ':8080' | awk '{print $4}' || echo 'nada na 8080'

echo
echo "== 2. o Jenkins responde por dentro? =="
printf '  127.0.0.1:8080/login -> '
curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 http://127.0.0.1:8080/login

echo
echo "== 3. a barreira de senha (nginx) =="
if command -v nginx >/dev/null 2>&1; then
  printf '  nginx:   '; systemctl is-active nginx 2>/dev/null || echo inativo
  printf '  htpasswd: '; [ -f /etc/nginx/jenkins.htpasswd ] && echo presente || echo AUSENTE
  echo '  sites habilitados:'
  ls /etc/nginx/sites-enabled/ 2>/dev/null | sed 's/^/    /' || echo '    (nenhum)'
  printf '  127.0.0.1:8081 sem senha -> '
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 http://127.0.0.1:8081/login
else
  echo '  nginx AUSENTE -- nao ha barreira de senha nesta maquina'
fi

echo
echo "== 4. a URL raiz configurada =="
# ⚠️ Este valor NAO e derivado da requisicao: e configuracao, e envelhece calado.
# Com ele errado o Jenkins valida a senha e manda o navegador para um endereco
# morto -- indistinguivel de "senha recusada" para quem esta na cadeira.
ARQ=/var/lib/jenkins/jenkins.model.JenkinsLocationConfiguration.xml
if [ -f "$ARQ" ]; then
  grep -oP '(?<=<jenkinsUrl>)[^<]*' "$ARQ" | sed 's/^/  /'
else
  echo '  (arquivo nao existe -- Jenkins nunca teve URL raiz definida)'
fi

echo
echo "== 5. quem alcanca a tela de login =="
# A conta do Jenkins esta nos grupos docker/k3s: passar da tela nao e ganhar
# "o Jenkins", e ganhar a maquina que roda os dez projetos.
#
# ⚠️ MEDIDO, e nao suposto: a rede do WSL2 aqui e NAT. O IP da distro
# (172.29.x) NAO e alcancavel da LAN -- so do proprio Windows. Entao `*:8080`
# nesta distro nao e "exposto ao Wi-Fi", como a primeira versao deste script
# dizia; e "exposto a quem ja esta no Windows, e a qualquer portproxy futuro".
#
# Continua valendo fechar: publicar a porta e UMA LINHA de `netsh`, e ninguem
# que a escrever vai lembrar que do outro lado nao havia senha.
#
# 🐞 O Jetty abre socket IPv6: 127.0.0.1 aparece como `[::ffff:127.0.0.1]`.
BIND=$(ss -ltn 2>/dev/null | grep ':8080' | awk '{print $4}' | head -1)
case "$BIND" in
  127.0.0.1:*|"[::ffff:127.0.0.1]":*|"[::1]":*)
    echo "  $BIND -- so a propria distro; quem vem de fora passa pelo nginx :8081  ✅" ;;
  *)
    echo "  ⚠️ $BIND -- aberto na distro: quem alcancar a distro PULA a barreira de senha" ;;
esac

#!/usr/bin/env bash
# Põe a barreira de senha na frente do Jenkins e fecha o acesso direto a ele.
#
#     wsl -d prd -u root -- bash -c "tr -d '\r' < /mnt/e/.../publicar-jenkins.sh > /tmp/p.sh; bash /tmp/p.sh"
#
# ===========================================================================
# O QUE ESTE SCRIPT MONTA
# ===========================================================================
#     internet → Cloudflare → túnel → :8081 nginx (SENHA) → :8080 Jenkins
#                                         ↑
#                              acesso local também entra por aqui
#
# Uma porta só, uma senha só. O Jenkins passa a escutar apenas em 127.0.0.1,
# então não existe caminho que não passe pela senha.
#
# ⚠️ Rodar de novo é seguro: a senha só é gerada se ainda não existir, e o
# resto é idempotente. Ele NÃO reimprime a senha já existente (ela é bcrypt no
# htpasswd, não dá para voltar) — a cópia em claro fica em
# /root/senha-jenkins-externa.txt.
set -uo pipefail

CONF_ORIGEM=/mnt/e/Desenvolvimento/Dev/Workspace/gateway/estacao/prd-wsl/nginx-jenkins.conf
HTPASSWD=/etc/nginx/jenkins.htpasswd
GUARDADA=/root/senha-jenkins-externa.txt
USUARIO=samuel
J=http://127.0.0.1:8080

falhou=0
passo() { echo; echo "== $* =="; }

# ---------------------------------------------------------------------------
passo "1. nginx e ferramentas"
if ! command -v nginx >/dev/null 2>&1; then
  echo "  instalando..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx apache2-utils >/dev/null 2>&1
fi
command -v nginx    >/dev/null 2>&1 || { echo "  ❌ nginx nao instalou";    exit 1; }
command -v htpasswd >/dev/null 2>&1 || {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apache2-utils >/dev/null 2>&1
}
command -v htpasswd >/dev/null 2>&1 || { echo "  ❌ htpasswd nao instalou"; exit 1; }
echo "  nginx:    $(nginx -v 2>&1)"
echo "  htpasswd: presente"

# ---------------------------------------------------------------------------
passo "2. a senha"
if [ -f "$HTPASSWD" ]; then
  echo "  htpasswd ja existe -- mantido (nao regenero para nao invalidar o que voce ja salvou)"
else
  # ⚠️ bcrypt (-B), e nao o apr1 padrao. O apr1 e MD5, e este arquivo protege
  # uma tela cujo dono e root na maquina que roda o Urupix.
  SENHA=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
  htpasswd -cbB "$HTPASSWD" "$USUARIO" "$SENHA" >/dev/null 2>&1
  chown root:www-data "$HTPASSWD"; chmod 640 "$HTPASSWD"
  umask 077; printf 'usuario: %s\nsenha:   %s\n' "$USUARIO" "$SENHA" > "$GUARDADA"
  echo "  gerada. usuario=$USUARIO"
  echo "  SENHA: $SENHA"
  echo "  (copia em $GUARDADA, so root le)"
fi

# ---------------------------------------------------------------------------
passo "3. o site do nginx"
[ -f "$CONF_ORIGEM" ] || { echo "  ❌ nao achei $CONF_ORIGEM"; exit 1; }
# ⚠️ `tr -d` porque o arquivo vem de um disco Windows: CRLF dentro de diretiva
# do nginx passa no `-t` e quebra o valor em silencio.
tr -d '\r' < "$CONF_ORIGEM" > /etc/nginx/sites-available/jenkins
ln -sf /etc/nginx/sites-available/jenkins /etc/nginx/sites-enabled/jenkins
# O site padrao ocupa a 80 -- que nesta distro e do Kong.
rm -f /etc/nginx/sites-enabled/default
nginx -t 2>&1 | sed 's/^/  /' || { echo "  ❌ configuracao invalida"; exit 1; }

# 🐞 `restart`, e nao `reload`. Depois de remover um site, o reload deixa os
# processos antigos vivos ainda escutando na porta que era dele. Na VM o nginx
# seguiu em 0.0.0.0:80 por isso, e so o restart fechou.
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx
sleep 1
printf '  nginx: '; systemctl is-active nginx

# ---------------------------------------------------------------------------
passo "4. a barreira responde?"
SEM=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:8081/login)
echo "  sem senha  -> $SEM   (esperado 401)"
[ "$SEM" = "401" ] || { echo "  ❌ a barreira NAO esta barrando"; falhou=1; }

if [ -f "$GUARDADA" ]; then
  S=$(sed -n 's/^senha:  *//p' "$GUARDADA")
  COM=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -u "$USUARIO:$S" http://127.0.0.1:8081/login)
  echo "  com senha  -> $COM   (esperado 200)"
  [ "$COM" = "200" ] || { echo "  ❌ a senha nao passa"; falhou=1; }
fi

# ⚠️ A pagina do 401 nao pode dizer que ha Jenkins atras: o ponto inteiro da
# barreira e o varredor automatico nao saber o que encontrou.
if curl -s --max-time 10 http://127.0.0.1:8081/login | grep -qi jenkins; then
  echo "  ⚠️ a pagina de 401 MENCIONA Jenkins -- a barreira entrega o que protege"
  falhou=1
else
  echo "  o 401 nao revela o que ha atras  ✅"
fi

# ---------------------------------------------------------------------------
passo "5. fechar o Jenkins em 127.0.0.1"
# Enquanto ele escuta em `*:8080`, quem alcancar a distro pula a barreira
# inteira. Hoje so o proprio Windows alcanca (a rede do WSL2 e NAT), mas isso
# depende de nenhum portproxy publicar a porta -- e portproxy e uma linha.
T=$(tr -d '\r\n' < /var/lib/jenkins/secrets/api-token 2>/dev/null)
OCUPADOS=$(curl -s --max-time 15 -u "samuca:$T" "$J/computer/api/json?tree=busyExecutors" \
           | grep -o '[0-9]\+' | head -1)
OCUPADOS=${OCUPADOS:-desconhecido}
echo "  executores ocupados: $OCUPADOS"

if [ "$OCUPADOS" != "0" ]; then
  # ⚠️ Reiniciar o Jenkins com esteira em andamento ABORTA o que estiver
  # rodando, depois de todo o trabalho ja feito. Nao vale a pena: o fechamento
  # do bind pode esperar a fila esvaziar.
  echo "  ⏸  NAO vou reiniciar: ha esteira rodando (ou nao consegui medir)."
  echo "     Rode este script de novo quando a fila estiver vazia."
else
  mkdir -p /etc/systemd/system/jenkins.service.d
  cat > /etc/systemd/system/jenkins.service.d/10-so-local.conf <<'UNIDADE'
# Prende o Jenkins em 127.0.0.1. Quem vem de fora entra pelo nginx :8081, que
# pede senha antes. Ver gateway/estacao/prd-wsl/nginx-jenkins.conf.
#
# ⚠️ Os scripts de dentro da distro (religar-hmg.sh, esteira.sh) chamam
# http://127.0.0.1:8080 e continuam funcionando -- eles ja estao "dentro".
[Service]
Environment="JENKINS_LISTEN_ADDRESS=127.0.0.1"
UNIDADE
  systemctl daemon-reload
  systemctl restart jenkins
  echo "  aguardando o Jenkins voltar..."
  for i in $(seq 1 60); do
    C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$J/login" 2>/dev/null)
    [ "$C" = "200" ] && { echo "  de volta (tentativa $i)"; break; }
    sleep 5
  done
  BIND=$(ss -ltn 2>/dev/null | grep ':8080' | awk '{print $4}' | head -1)
  echo "  bind agora: $BIND"
  # 🐞 O Jetty do Jenkins abre socket IPv6, entao `--httpListenAddress=127.0.0.1`
  # aparece no `ss` como `[::ffff:127.0.0.1]:8080` -- a forma IPv4-mapeada. E o
  # mesmo endereco fechado, escrito de outro jeito.
  #
  # ⚠️ A primeira versao desta guarda so aceitava `127.0.0.1:*` e reprovou o
  # bind CORRETO, mandando procurar defeito onde nao havia. Guarda que reprova o
  # estado certo custa mais caro que guarda nenhuma.
  case "$BIND" in
    127.0.0.1:*|"[::ffff:127.0.0.1]":*|"[::1]":*) echo "  fechado  ✅" ;;
    *)                                            echo "  ⚠️ ainda aberto em $BIND"; falhou=1 ;;
  esac
fi

# ---------------------------------------------------------------------------
passo "6. a URL raiz do Jenkins"
# 🐞 Este valor NAO e derivado da requisicao. Com ele errado o Jenkins valida a
# senha corretamente e manda o navegador para um endereco morto -- e da cadeira
# de quem usa isso e indistinguivel de senha recusada, o que leva a pessoa a
# duvidar da propria senha. Ja custou um dia na VM.
#
# ⚠️ Sempre que o endereco de acesso mudar, ISTO tem de mudar junto.
T=$(tr -d '\r\n' < /var/lib/jenkins/secrets/api-token 2>/dev/null)
CR=$(curl -s --max-time 20 -u "samuca:$T" "$J/crumbIssuer/api/json" \
     | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"]+":"+d["crumb"])' 2>/dev/null)
if [ -n "${CR:-}" ]; then
  curl -s --max-time 30 -u "samuca:$T" -H "$CR" --data-urlencode 'script=
import jenkins.model.JenkinsLocationConfiguration
def c = JenkinsLocationConfiguration.get()
c.setUrl("https://jenkins.cursodetecnologia.dev.br/")
c.save()
println "  url raiz = " + c.getUrl()
' "$J/scriptText" | sed 's/^/  /'
else
  echo "  ⚠️ nao consegui falar com a API (sem token?) -- defina a URL raiz a mao"
fi

echo
if [ "$falhou" = "0" ]; then
  echo "✅ barreira de pe. Falta o lado Windows: portproxy 8081 e a regra do tunel."
else
  echo "❌ terminou com pendencia -- leia os ❌ acima antes de publicar o DNS."
fi
exit "$falhou"

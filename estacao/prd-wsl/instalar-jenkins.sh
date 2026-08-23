#!/usr/bin/env bash
# ===========================================================================
# O Jenkins da producao local — na distro `prd`, fora do Docker.
#
#     wsl -d prd -u root -- bash /mnt/e/.../instalar-jenkins.sh
#
# Idempotente.
# ===========================================================================
#
# ⚠️ SERVICO DO SYSTEMD, e nao Pod.
#
# Na `serverhomol` o Jenkins tambem era servico do sistema, e nao carga do
# cluster. Nao e detalhe de gosto: os scripts de configuracao que estao
# versionados (`gateway/vm/*.groovy`) escrevem em `/var/lib/jenkins/...` e leem
# segredos de `/var/lib/jenkins/secrets/`. Como Pod, cada um deles precisaria
# ser reescrito.
#
# E ele PRECISA construir imagem. Fora do cluster, com o atalho `docker` que
# aponta para o containerd do k3s, ele constroi direto no armazenamento que o
# cluster usa -- sem Docker em lugar nenhum da cadeia.
set -euo pipefail

diga() { echo "  $*"; }
REPO=/mnt/e/Desenvolvimento/Dev/Workspace/gateway
# A pasta DESTE script -- e de onde vem a lista de plugins.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# 1. O pacote
# ---------------------------------------------------------------------------
if ! command -v jenkins >/dev/null 2>&1 && [ ! -f /usr/share/java/jenkins.war ]; then
  diga "instalando o Jenkins (LTS)..."
  install -m 0755 -d /usr/share/keyrings
  # 🐞 A chave do repositorio MUDA de ano em ano, e o endereco antigo continua
  # respondendo 200 com a chave VELHA. O sintoma nao diz isso: o apt reclama
  # "NO_PUBKEY 7198F4B714ABFC68" e "repository is not signed", que parece
  # espelho corrompido ou rede filtrando o trafego.
  #
  # ⚠️ Por isso o nome do arquivo e DESCOBERTO na listagem, e nao fixado.
  # Fixar `jenkins.io-2023.key` funcionou por dois anos e passou a falhar
  # baixando com SUCESSO a chave errada -- que e o pior jeito de falhar.
  chave=$(curl -s https://pkg.jenkins.io/debian-stable/ \
          | grep -oE 'jenkins[.]io-[0-9]{4}[.]key' | sort -u | tail -1)
  diga "chave do repositorio: ${chave}"
  curl -fsSL "https://pkg.jenkins.io/debian-stable/${chave}" \
    | gpg --dearmor > /usr/share/keyrings/jenkins-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.gpg] https://pkg.jenkins.io/debian-stable binary/" \
    > /etc/apt/sources.list.d/jenkins.list
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq jenkins >/dev/null
fi
diga "jenkins: $(dpkg-query -W -f='${Version}' jenkins 2>/dev/null || echo '?')"

# ---------------------------------------------------------------------------
# 1b. Os PLUGINS — sem eles o Jenkins sobe vazio
# ---------------------------------------------------------------------------
#
# 🐞 Um Jenkins recem-instalado nao tem plugin nenhum, e os scripts de
# `init.groovy.d` falham com `unable to resolve class`. O servico fica ATIVO,
# a tela abre, e nao existe job nenhum -- de pe e inutil, que engana quem so
# confere se subiu.
#
# ⚠️ A lista fica em arquivo proprio (`plugins-do-jenkins.txt`) porque ela nao
# e "o que veio junto": e o que a NOSSA configuracao exige. O gerenciador
# resolve as dependencias sozinho.
LISTA="$REPO_DIR/plugins-do-jenkins.txt"
if [ ! -f /var/lib/jenkins/plugins/workflow-multibranch.jpi ] && [ -f "$LISTA" ]; then
  diga "instalando os plugins..."
  if [ ! -s /opt/plugin-manager.jar ]; then
    # ⚠️ A versao vem da API, e nao fixada no codigo: um numero fixo vira 404
    # silencioso quando o projeto publica a proxima -- e `curl -o` deixa um
    # arquivo VAZIO, que so aparece como "Unable to access jarfile".
    url=$(curl -sL https://api.github.com/repos/jenkinsci/plugin-installation-manager-tool/releases/latest \
          | grep -oE 'https://[^"]*jenkins-plugin-manager-[0-9.]+[.]jar' | head -1)
    if [ -z "$url" ]; then
      echo "  ERRO: nao descobri a versao do gerenciador de plugins." >&2
      exit 1
    fi
    curl -fL --retry 3 --max-time 300 -o /opt/plugin-manager.jar "$url"
  fi
  java -jar /opt/plugin-manager.jar \
    --war /usr/share/java/jenkins.war \
    --plugin-download-directory /var/lib/jenkins/plugins \
    --plugin-file "$LISTA" 2>&1 | tail -3
  chown -R jenkins:jenkins /var/lib/jenkins/plugins
fi
diga "plugins: $(ls -1 /var/lib/jenkins/plugins/*.jpi 2>/dev/null | wc -l)"

# ---------------------------------------------------------------------------
# 2. O que o Jenkins precisa alcancar
# ---------------------------------------------------------------------------
#
# ⚠️ O usuario `jenkins` precisa falar com o k3s e com o containerd. Sem isto o
# estagio de implantacao morre com "connection refused" no kubectl -- que
# parece cluster fora do ar e e permissao de arquivo.
usermod -aG root jenkins 2>/dev/null || true
install -d -o jenkins -g jenkins -m 0700 /var/lib/jenkins/secrets
install -d -o jenkins -g jenkins -m 0755 /var/lib/jenkins/init.groovy.d
install -d -o jenkins -g jenkins -m 0755 /var/lib/jenkins/userContent

# O kubeconfig do k3s, numa copia que o jenkins consegue ler.
install -d -o jenkins -g jenkins -m 0700 /var/lib/jenkins/.kube
cp /etc/rancher/k3s/k3s.yaml /var/lib/jenkins/.kube/config
chown jenkins:jenkins /var/lib/jenkins/.kube/config
chmod 600 /var/lib/jenkins/.kube/config

# `kubectl` avulso: os Jenkinsfile chamam `$KUBECTL`, nao `k3s kubectl`.
if [ ! -x /usr/local/bin/kubectl ]; then
  ln -sf /usr/local/bin/nerdctl /dev/null 2>/dev/null || true
  cat > /usr/local/bin/kubectl <<'ATALHO'
#!/usr/bin/env bash
exec /usr/local/bin/k3s kubectl "$@"
ATALHO
  chmod +x /usr/local/bin/kubectl
fi

# ---------------------------------------------------------------------------
# 3. A chave do GitHub
# ---------------------------------------------------------------------------
#
# 🔴 DIVIDA CONHECIDA, repetida de proposito para nao sumir: esta e a chave
# PESSOAL do Samuel, com permissao de ESCRITA nos repositorios. Na
# `serverhomol` era a mesma, e ja estava anotada como divida em
# `vm/DIVIDA-SEGURANCA.md`.
#
# O certo e uma chave de implantacao (deploy key), so de leitura, por
# repositorio. Fica registrado aqui como pendencia, nao como decisao.
if [ -f /mnt/c/Users/samue/.ssh/id_ed25519 ] && [ ! -f /var/lib/jenkins/.ssh/id_ed25519 ]; then
  install -d -o jenkins -g jenkins -m 0700 /var/lib/jenkins/.ssh
  cp /mnt/c/Users/samue/.ssh/id_ed25519 /var/lib/jenkins/.ssh/id_ed25519
  chown jenkins:jenkins /var/lib/jenkins/.ssh/id_ed25519
  chmod 600 /var/lib/jenkins/.ssh/id_ed25519
  ssh-keyscan -t rsa,ecdsa,ed25519 github.com > /var/lib/jenkins/.ssh/known_hosts 2>/dev/null
  chown jenkins:jenkins /var/lib/jenkins/.ssh/known_hosts
  diga "chave do github instalada (DIVIDA: e a pessoal, com escrita)"
fi

# ⚠️ E a MESMA chave tambem no caminho que o `jenkins-ssh-e-jobs.groovy`
# procura. Sao dois usos diferentes: `~/.ssh` serve ao `git` da linha de
# comando; `secrets/github-ssh-key` e de onde o script monta a CREDENCIAL que
# os jobs multibranch usam. Faltando a segunda, os jobs nascem sem credencial e
# a varredura falha em "Permission denied (publickey)" -- que parece chave
# errada, e e chave ausente noutro lugar.
if [ -f /mnt/c/Users/samue/.ssh/id_ed25519 ] && [ ! -f /var/lib/jenkins/secrets/github-ssh-key ]; then
  cp /mnt/c/Users/samue/.ssh/id_ed25519 /var/lib/jenkins/secrets/github-ssh-key
  chown jenkins:jenkins /var/lib/jenkins/secrets/github-ssh-key
  chmod 600 /var/lib/jenkins/secrets/github-ssh-key
  diga "credencial ssh dos jobs instalada"
fi

# ---------------------------------------------------------------------------
# 4. Os scripts de configuracao — o Jenkins como CODIGO
# ---------------------------------------------------------------------------
#
# ⚠️ Sao eles que devolvem os jobs, as visoes, o executor unico e a politica de
# seguranca do painel. Sem isto o Jenkins sobe vazio, e alguem teria que
# recriar dez jobs multibranch pela tela -- que e como a configuracao vira
# lenda em vez de arquivo.
# 🐞 A ORDEM E ALFABETICA, e foi isso que derrubou a primeira tentativa.
#
# O Jenkins executa `init.groovy.d` por ordem de NOME DE ARQUIVO. Pus
# `jenkins-usuarios` primeiro na lista do `for` achando que bastava, e ele
# rodou DEPOIS de `jenkins-token-api` -- que precisa da conta `samuca` já
# existindo. O aviso "usuario nao existe -- token NAO criado" parecia defeito
# do script do token; era ordem de execucao.
#
# Por isso o prefixo `00-`: quem precisa vir antes carrega isso no NOME.
copiar() {
  local origem="$REPO/vm/$1.groovy"
  local destino="/var/lib/jenkins/init.groovy.d/$2.groovy"
  [ -f "$origem" ] || return 0
  cp "$origem" "$destino"
  chown jenkins:jenkins "$destino"
}
rm -f /var/lib/jenkins/init.groovy.d/jenkins-usuarios.groovy
copiar jenkins-usuarios 00-jenkins-usuarios
for g in jenkins-ssh-e-jobs painel-jenkins um-executor csp-do-painel \
         jenkins-credencial jenkins-credencial-sonar jenkins-token-api \
         jenkins-vigia-backups; do
  copiar "$g" "$g"
done
diga "scripts de configuracao: $(ls -1 /var/lib/jenkins/init.groovy.d/*.groovy 2>/dev/null | wc -l)"

# ---------------------------------------------------------------------------
# 5. O painel e o tema
# ---------------------------------------------------------------------------
install -d -o jenkins -g jenkins -m 0755 /var/lib/jenkins/userContent/painel
install -d -o jenkins -g jenkins -m 0755 /var/lib/jenkins/userContent/tema
cp "$REPO"/vm/painel/painel.* /var/lib/jenkins/userContent/painel/ 2>/dev/null || true
cp "$REPO"/vm/tema/cinza.css /var/lib/jenkins/userContent/tema/ 2>/dev/null || true
chown -R jenkins:jenkins /var/lib/jenkins/userContent
diga "painel: $(ls -1 /var/lib/jenkins/userContent/painel/ 2>/dev/null | tr '\n' ' ')"

# O coletor de saude das tarefas agendadas, com o temporizador.
cp "$REPO/vm/painel/coletar-jobs.py" /usr/local/bin/coletar-jobs.py 2>/dev/null || true
chmod +x /usr/local/bin/coletar-jobs.py 2>/dev/null || true
if [ ! -f /etc/systemd/system/coletar-jobs.timer ]; then
  cat > /etc/systemd/system/coletar-jobs.service <<'UNIDADE'
[Unit]
Description=Coleta a saude dos CronJobs para o painel
[Service]
Type=oneshot
ExecStart=/usr/local/bin/coletar-jobs.py
UNIDADE
  cat > /etc/systemd/system/coletar-jobs.timer <<'UNIDADE'
[Unit]
Description=A cada minuto, a saude das tarefas agendadas
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
UNIDADE
  systemctl daemon-reload
fi
# ⚠️ O coletor usa `microk8s kubectl` por heranca da VM. Aqui e `k3s kubectl`.
sed -i 's|^KUBECTL = .*|KUBECTL = ["k3s", "kubectl"]|' /usr/local/bin/coletar-jobs.py 2>/dev/null || true
systemctl enable --now coletar-jobs.timer >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 6. Subir
# ---------------------------------------------------------------------------
systemctl enable jenkins >/dev/null 2>&1 || true
systemctl restart jenkins
diga "esperando o Jenkins responder..."
for i in $(seq 1 60); do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:8080/login || true)
  if [ "$c" = "200" ] || [ "$c" = "403" ]; then diga "jenkins responde ($c)"; break; fi
  sleep 5
done
diga "estado: $(systemctl is-active jenkins)"

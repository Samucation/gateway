#!/usr/bin/env bash
# ===========================================================================
# Prepara a distro `prd` para segurar a producao FORA do Docker Desktop.
#
#     wsl -d prd -u root -- bash /mnt/e/.../preparar-distro.sh
#
# Idempotente: rodar de novo nao estraga nada, so confere.
# ===========================================================================
#
# ⚠️ ESTE ARQUIVO EXISTE PORQUE COMANDO SOLTO NAO SOBREVIVE.
#
# 🐞 As primeiras tentativas foram por `wsl -d prd -- bash -lc "..."`, com o
# comando inteiro entre aspas. Duas camadas de shell depois, `${V}` e `$?`
# chegavam mastigados: o `curl` respondia SUCESSO e o arquivo nao existia. Meia
# hora procurando defeito de rede que nao havia.
#
# Script em arquivo, versionado, chamado por caminho. Sem aspas aninhadas.
set -euo pipefail

diga() { echo "  $*"; }

# ---------------------------------------------------------------------------
# 1. Pacotes de base
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
diga "instalando pacotes de base..."
apt-get update -qq
apt-get install -y -qq \
  openjdk-21-jre-headless git jq unzip curl ca-certificates \
  postgresql-client iproute2 uidmap >/dev/null
diga "java: $(java -version 2>&1 | head -1)"

# ---------------------------------------------------------------------------
# 1a. Node -- a esteira roda `npm` DIRETO no agente, sem conteiner
# ---------------------------------------------------------------------------
#
# 🐞 O estagio de testes dos projetos Node chama `npm ci` e `npm test` na
# propria maquina do Jenkins (so o BUILD da imagem e em conteiner). Sem Node
# instalado o estagio morre com
#
#     script.sh: 6: npm: not found       (exit 127)
#
# ...e o `127` nao aparece em lugar nenhum como "falta instalar": o painel
# mostra "Testes + cobertura FAILED" e o log some no meio de vinte linhas de
# limpeza do post-actions.
if ! command -v npm >/dev/null 2>&1; then
  diga "instalando Node LTS..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs >/dev/null 2>&1
fi
diga "node: $(node --version 2>&1) | npm: $(npm --version 2>&1)"

# ---------------------------------------------------------------------------
# 1b. DNS fixo — o buildkit nao se da bem com o resolvedor do WSL
# ---------------------------------------------------------------------------
#
# 🐞 O `docker build` morria assim, com a rede da distro FUNCIONANDO:
#
#   failed to fetch anonymous token: dial tcp: lookup auth.docker.io
#   on 10.255.255.254:53: no such host
#
# `curl` para o mesmo endereco respondia normalmente, e `getent hosts` resolvia
# -- devolvendo IPv6. O resolvedor que o WSL instala (10.255.255.254) e um
# encaminhador para o Windows, e o buildkit tropeça nele.
#
# ⚠️ O engano aqui e caro: a mensagem culpa o DNS, a rede esta boa, e a
# tentacao e ir mexer em firewall ou em proxy. O problema e SO do resolvedor
# gerado automaticamente.
#
# ⚠️ E A CORRECAO E NO systemd-resolved, NAO no arquivo.
#
# 🐞 Primeiro eu escrevi `/etc/resolv.conf` a mao. Funcionou ate a distro
# reiniciar: com systemd ligado, o `systemd-resolved` reassume o arquivo como
# LINK para o stub dele, e o meu conteudo some sem aviso.
#
# O erro seguinte foi outro e igualmente enganoso:
#
#   lookup registry-1.docker.io on 127.0.0.53:53: server misbehaving
#
# `127.0.0.53` e o stub do proprio resolved -- ou seja, ele estava no caminho e
# sem para onde encaminhar. Duas mensagens de DNS diferentes, a mesma causa
# raiz: quem resolve nome aqui e o resolved, e e nele que se configura.
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/dns.conf <<'DNS'
# Fixo de proposito -- ver a explicacao no `preparar-distro.sh`.
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=9.9.9.9
DNSStubListener=yes
DNS
systemctl restart systemd-resolved 2>/dev/null || true
sleep 2
diga "dns: $(resolvectl status 2>/dev/null | grep -c '1.1.1.1') caminho(s) para 1.1.1.1"

# ---------------------------------------------------------------------------
# 2. nerdctl + buildkit — o construtor de imagens SEM Docker
# ---------------------------------------------------------------------------
#
# ⚠️ Por que nerdctl e nao Docker Engine: ele fala com o MESMO containerd que o
# k3s usa. A imagem construida ja nasce onde o cluster a procura -- sem
# `push`/`pull` de ida e volta num registro que fica na mesma maquina.
#
# E a linha de comando e compativel com a do Docker no que a esteira usa
# (`build`, `push`, `run`, `image prune`), entao os Jenkinsfile seguem valendo.
NERDCTL_VERSAO="2.1.2"
if [ ! -x /usr/local/bin/nerdctl ]; then
  diga "baixando nerdctl ${NERDCTL_VERSAO}..."
  url="https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSAO}/nerdctl-full-${NERDCTL_VERSAO}-linux-amd64.tar.gz"
  curl -fL --retry 3 --max-time 600 -o /tmp/nerdctl.tgz "$url"
  # ⚠️ Confere o TAMANHO antes de extrair. Um 404 da GitHub vem como pagina
  # HTML de 9 KB, e o `tar` reclamaria de formato -- mensagem que manda
  # procurar no lugar errado.
  tamanho=$(stat -c%s /tmp/nerdctl.tgz)
  if [ "$tamanho" -lt 10000000 ]; then
    echo "  ERRO: o download tem ${tamanho} bytes; nao e o pacote." >&2
    exit 1
  fi
  tar -C /usr/local -xzf /tmp/nerdctl.tgz
  rm -f /tmp/nerdctl.tgz
fi
diga "nerdctl: $(/usr/local/bin/nerdctl --version)"

# O `buildkitd` vem no pacote `nerdctl-full`, mas sem unidade do systemd.
if [ ! -f /etc/systemd/system/buildkit.service ]; then
  cat > /etc/systemd/system/buildkit.service <<'UNIDADE'
[Unit]
Description=BuildKit - construtor de imagens do k3s
Documentation=https://github.com/moby/buildkit
After=k3s.service

[Service]
# ⚠️ Aponta para o containerd DO K3S, e nao para um proprio.
#
# Sem `--oci-worker=false --containerd-worker=true`, o buildkit sobe um
# armazenamento SEPARADO: a imagem e construida com sucesso e o cluster nao a
# encontra. Verde que nao entrega nada -- o defeito da casa.
ExecStart=/usr/local/bin/buildkitd \
  --oci-worker=false \
  --containerd-worker=true \
  --containerd-worker-addr=/run/k3s/containerd/containerd.sock \
  --containerd-worker-namespace=k8s.io
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIDADE
  systemctl daemon-reload
fi
systemctl enable --now buildkit >/dev/null 2>&1 || true
diga "buildkit: $(systemctl is-active buildkit)"

# ---------------------------------------------------------------------------
# 3. O atalho `docker` — para os Jenkinsfile nao precisarem mudar
# ---------------------------------------------------------------------------
#
# Os treze Dockerfile dos oito sistemas de producao foram conferidos: nenhum usa
# recurso exclusivo do BuildKit. O que a esteira chama de `docker` o nerdctl
# atende com a mesma sintaxe.
#
# ⚠️ O `--namespace k8s.io` NAO e detalhe: e o espaco de nomes onde o k3s
# procura imagem. Construir no espaco padrao (`default`) daria build verde e
# `ErrImageNeverPull` na hora de subir o Pod.
if [ ! -x /usr/local/bin/docker ]; then
  cat > /usr/local/bin/docker <<'ATALHO'
#!/usr/bin/env bash
# ⚠️ `--address` TAMBEM e obrigatorio, e a falta dele nao parece o que e.
#
# 🐞 So com `--namespace k8s.io` o nerdctl procura o containerd no caminho
# padrao (`/run/containerd/containerd.sock`) e morre com "cannot access
# containerd socket". Parece containerd ausente -- e ele esta la, no soquete
# DO K3S, noutro caminho.
exec /usr/local/bin/nerdctl   --address /run/k3s/containerd/containerd.sock   --namespace k8s.io "$@"
ATALHO
  chmod +x /usr/local/bin/docker
fi
diga "docker -> $(readlink -f /usr/local/bin/docker) (nerdctl no espaco k8s.io)"

# ---------------------------------------------------------------------------
# 4. Conferencia
# ---------------------------------------------------------------------------
diga ""
diga "== conferindo =="
diga "k3s:      $(systemctl is-active k3s)"
diga "no:       $(k3s kubectl get nodes --no-headers 2>/dev/null | awk '{print $1, $2}')"
diga "registro: $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:32000/v2/)"
diga "buildkit: $(systemctl is-active buildkit)"

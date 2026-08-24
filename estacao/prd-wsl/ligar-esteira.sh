#!/usr/bin/env bash
# ===========================================================================
# Liga a esteira ao arranjo NOVO: k3s de producao + k3d de homologacao.
#
#     wsl -d prd -u root -- bash ligar-esteira.sh
#
# Idempotente.
# ===========================================================================
set -uo pipefail

diga() { echo "  $*"; }

# ---------------------------------------------------------------------------
# 1. O nome do Sonar
# ---------------------------------------------------------------------------
#
# ⚠️ `sonar.hmg` nao e DNS: e uma linha no `/etc/hosts`, apontando para o
# proprio no. Quem atende e o Ingress do Sonar, pelo Traefik na porta 80.
#
# 🐞 O Jenkins roda como SERVICO DO SISTEMA, fora do cluster -- e DNS de
# Service (`*.svc.cluster.local`) so existe para quem esta dentro. Trocar este
# nome por um de Service parece mais limpo e simplesmente nao resolve.
if ! grep -q 'sonar.hmg' /etc/hosts 2>/dev/null; then
  printf '127.0.0.1 sonar.hmg\n' >> /etc/hosts
  diga 'sonar.hmg apontado para 127.0.0.1 no /etc/hosts'
else
  diga 'sonar.hmg ja estava no /etc/hosts'
fi
diga "sonar responde: $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://sonar.hmg/api/system/status)"

# ---------------------------------------------------------------------------
# 2. O kubeconfig de HOMOLOGACAO
# ---------------------------------------------------------------------------
#
# O k3d vive no Docker Desktop da estacao. O Jenkins alcanca pelo IP do
# Windows visto de dentro da distro.
#
# ⚠️ O certificado do k3d cobre o IP da ESTACAO (192.168.15.9), e nao o
# endereco de roteamento do WSL. Apontar para o gateway padrao daria
# "certificate is valid for ..." -- erro que parece credencial e e de
# certificado.
ORIGEM=/mnt/c/Users/samue/.kube/config
DESTINO=/var/lib/jenkins/.kube/config-hmg
if [ -f "$ORIGEM" ]; then
  install -d -o jenkins -g jenkins -m 0700 /var/lib/jenkins/.kube
  # So o contexto do k3d, para nao levar junto credencial de outro cluster.
  kubectl --kubeconfig "$ORIGEM" config view --minify --flatten \
          --context=k3d-hmg > "$DESTINO" 2>/dev/null
  chown jenkins:jenkins "$DESTINO"; chmod 600 "$DESTINO"
  diga "kubeconfig de homologacao copiado"
else
  diga "⚠️ nao achei o kubeconfig do Windows em $ORIGEM"
fi

# O endereco `0.0.0.0` ou `127.0.0.1` no kubeconfig aponta para a PROPRIA
# distro. De dentro dela, o k3d esta no IP da estacao.
if [ -f "$DESTINO" ]; then
  # ⚠️ Tres enderecos possiveis, e o terceiro me pegou: alem de `0.0.0.0` e
  # `127.0.0.1`, o k3d escreve `host.docker.internal` -- um nome que so existe
  # DENTRO do Docker Desktop. De fora dele nao resolve, e o erro fala de
  # "couldn't get server API group list", que parece cluster fora do ar.
  sed -i -E 's#server: https://(0\.0\.0\.0|127\.0\.0\.1|host\.docker\.internal):#server: https://192.168.15.9:#' "$DESTINO"
  diga "servidor de hmg: $(grep -m1 'server:' "$DESTINO" | tr -d ' ')"
  if kubectl --kubeconfig "$DESTINO" get nodes >/dev/null 2>&1; then
    diga "homologacao alcancada ✅"
  else
    diga "⚠️ NAO alcancei homologacao -- o Docker Desktop precisa estar ligado"
  fi
fi

# ---------------------------------------------------------------------------
# 2b. O `docker` do usuario jenkins
# ---------------------------------------------------------------------------
#
# 🐞 O atalho `docker` fala com o containerd DO K3S, cujo soquete e de root.
# Rodando como `jenkins`, o nerdctl nao alcanca e responde:
#
#   rootless containerd not running? (hint: use containerd-rootless-setuptool)
#
# ...que manda instalar modo sem-root -- caminho errado. O soquete existe e
# esta funcionando; o que falta e permissao.
#
# ⚠️ Mudar o dono do soquete nao resolve: o k3s o recria a cada partida. Por
# isso o atalho passa a chamar `sudo` quando nao for root, com uma regra
# limitada a ESTE binario.
if ! grep -q 'jenkins.*nerdctl' /etc/sudoers.d/jenkins-nerdctl 2>/dev/null; then
  printf 'jenkins ALL=(root) NOPASSWD: /usr/local/bin/nerdctl
' > /etc/sudoers.d/jenkins-nerdctl
  chmod 440 /etc/sudoers.d/jenkins-nerdctl
fi
cat > /usr/local/bin/docker <<'ATALHO'
#!/usr/bin/env bash
# Traduz `docker` para o nerdctl do containerd DO K3S.
#
# ⚠️ `--address` e `--namespace` sao obrigatorios: sem o primeiro o nerdctl
# procura o soquete no caminho padrao e diz "cannot access containerd socket";
# sem o segundo constroi num espaco que o k3s nao consulta, e o Pod sobe com
# `ErrImageNeverPull` depois de um build verde.
ARGS=(--address /run/k3s/containerd/containerd.sock --namespace k8s.io)
if [ "$(id -u)" -eq 0 ]; then
  exec /usr/local/bin/nerdctl "${ARGS[@]}" "$@"
fi
exec sudo -n /usr/local/bin/nerdctl "${ARGS[@]}" "$@"
ATALHO
chmod +x /usr/local/bin/docker
diga 'atalho `docker` com sudo para o usuario jenkins'

# ---------------------------------------------------------------------------
# 3. O que a esteira chama e precisa existir
# ---------------------------------------------------------------------------
for cmd in kubectl docker git java; do
  if command -v "$cmd" >/dev/null 2>&1; then
    diga "$cmd: $(command -v $cmd)"
  else
    diga "⚠️ FALTA: $cmd"
  fi
done

# ⚠️ O usuario `jenkins` precisa alcancar o k3s e o containerd. Sem isto o
# estagio de implantacao morre com "connection refused" -- que parece cluster
# fora do ar e e permissao de arquivo.
install -d -o jenkins -g jenkins -m 0700 /var/lib/jenkins/.kube
cp /etc/rancher/k3s/k3s.yaml /var/lib/jenkins/.kube/config 2>/dev/null || true
chown jenkins:jenkins /var/lib/jenkins/.kube/config 2>/dev/null || true
chmod 600 /var/lib/jenkins/.kube/config 2>/dev/null || true
usermod -aG root jenkins 2>/dev/null || true
diga "kubeconfig de producao no lugar"

diga ''
diga '== conferindo pelo usuario jenkins =='
su - jenkins -s /bin/bash -c 'kubectl get nodes --no-headers 2>&1 | head -1' | sed 's/^/    prd: /'
su - jenkins -s /bin/bash -c 'kubectl --kubeconfig=/var/lib/jenkins/.kube/config-hmg get nodes --no-headers 2>&1 | head -1' | sed 's/^/    hmg: /'
su - jenkins -s /bin/bash -c 'docker images 2>&1 | head -1' | sed 's/^/    docker: /'

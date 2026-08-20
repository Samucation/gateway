# Dívidas de segurança em aberto

Coisas que estão **conscientemente** abaixo do que deveriam estar. Não são
descuidos — cada uma foi discutida, o risco foi exposto, e a escolha foi
destravar agora e revisar depois.

Este arquivo existe para que "depois" não vire "nunca".

---

## 1. 🔴 A chave SSH pessoal do Samuel está no Jenkins

**Desde:** 20/08/2026
**Onde:** credencial `github-ssh-samucation`, no cofre do Jenkins da VM
**Chave:** `id_ed25519`, `SHA256:blmlXuCMZ7UwfwJRTPSxQqjm+3O+HCDHBXHyOq/1iBQ`

### O risco, sem suavizar

Essa chave é a **identidade do Samuel no GitHub** e tem **escrita em todos os
repositórios** da conta `Samucation`.

O usuário `jenkins` daquela máquina está nos grupos `docker` e `microk8s` — o
que na prática é **root ali** (quem controla o Docker roda contêiner
privilegiado). Então:

> Quem comprometer a VM passa a ser o Samuel no GitHub, com poder de injetar
> código em qualquer repositório dele.

E injeção em repositório de CI é o tipo de estrago que se espalha sozinho: o
código injetado é construído e implantado pela própria esteira.

O CI só precisa **ler**. Isto é muito mais poder do que a tarefa exige.

### Por que está assim

A alternativa recomendada era um **token de escopo fino, somente leitura**. Ele
exige a sessão do GitHub no navegador — não existe API para criar Personal
Access Token, e isso é proposital (senão um token roubado geraria outros).

O risco foi apresentado com as três opções lado a lado. O Samuel optou por
destravar o ambiente agora e revisar depois, **com o risco registrado**.
Decisão dele, tomada com a informação na mão.

### O que foi feito para reduzir

- A chave vive **cifrada no cofre do Jenkins**, não como arquivo em `~/.ssh`.
- O arquivo em texto puro foi **apagado do disco** logo após a importação —
  senão ele entraria também nos backups, que é uma segunda cópia que ninguém
  lembra de proteger.
- O Jenkins escuta só em `127.0.0.1`, atrás do nginx com senha.

Nada disso muda o fundo: quem virar `root` na VM lê o cofre.

### Como sair — o caminho já está pronto

1. Criar o token de escopo fino (passo a passo em `system-api/k8s/jenkins.md`).
2. Entregá-lo ao Jenkins — o `jenkins-credencial.groovy` **já está instalado**
   e cria a credencial `github-samucation` sozinho.
3. A pasta `github-Samucation` **já existe** e já aponta para essa credencial;
   ela passa a descobrir os repositórios pela API.
4. Apagar `/var/lib/jenkins/init.groovy.d/jenkins-ssh-e-jobs.groovy`, remover a
   credencial `github-ssh-samucation` e os 10 jobs que ele criou.
5. ⚠️ **ROTACIONAR a `id_ed25519` no GitHub.** Ela esteve nesta máquina, e
   "esteve" é para sempre.

### O que se perde enquanto isso

**Descoberta automática.** A API lista os repositórios sozinha; por SSH não dá.
Os 10 jobs são uma **lista escrita à mão** em `jenkins-ssh-e-jobs.groovy` —
projeto novo **não aparece sozinho**, tem que ser acrescentado ali.

---

## 2. 🟡 Senha única no nginx, em vez de identidade

**Desde:** 20/08/2026
**Onde:** `/etc/nginx/jenkins.htpasswd` (bcrypt), usuário `samuel`

O Cloudflare Access seria melhor — bloqueio antes de chegar na máquina, login
pela conta Google, sem senha nova para guardar. Foi descartado porque a tela de
plano do Zero Trust **pede cartão de crédito** mesmo no Free.

O que se perde: uma senha compartilhada não diz **quem** entrou, não expira, e
não tem segundo fator. Para um CI de uma pessoa, é aceitável; no dia em que
outra pessoa precisar de acesso, isto deixa de ser aceitável.

**Consequência prática já observada:** o nginx apaga o cabeçalho
`Authorization` (necessário para o navegador funcionar), então a **API REST do
Jenkins não funciona pelo túnel**. Para API, use
`ssh -L 8080:127.0.0.1:8080 usuario@192.168.15.55`.

---

## 3. 🟡 A conta Cloudflare não tem segundo fator

**Observado:** 20/08/2026, em *My Profile → Access Management → Authentication*

Ela controla o DNS de `urupix.com.br`. Quem entrar nela **redireciona as
doações PIX para onde quiser**, sem tocar em nenhum servidor.

É hoje o elo mais fraco de toda a montagem: não adianta proteger o Jenkins com
senha se a conta que manda no domínio inteiro cai com uma senha só.

**Como resolver:** *Mobile App Authentication* (TOTP) é o mais forte dos três
oferecidos; o de e-mail é o mais fraco. Guardar os códigos de recuperação junto
com a chave `age` dos backups — mesma gaveta, mesmo tipo de "perdi isso, perdi
tudo".

---

## 4. 🟡 Segredos de homologação em claro no backup da VM

**Onde:** `G:\Backups\hmg\*/`

Os dumps vindos da VM não são cifrados, porque são dados de teste. Os `.env`
sim (`segredos.age`).

⚠️ **No dia em que houver dado real naquele cluster, isto tem que mudar** — o
`backup-estacao.ps1` já cifra tudo e serve de modelo.

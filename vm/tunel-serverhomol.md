# Túnel `serverhomol` — acesso ao Jenkins de fora da rede

O Jenkins vive na VM (`192.168.15.55:8080`) e só era alcançável de dentro de
casa. Este túnel é o caminho de fora.

---

## ⚠️ É um túnel PRÓPRIO, e não o `nerdquiz`

| Túnel | ID | Onde roda | Serve |
|---|---|---|---|
| `nerdquiz` | `47a05dc3…` | **esta estação** | tudo de `cursodetecnologia.dev.br` + `urupix.com.br` |
| `serverhomol` | `f0d7cd68…` | **a VM** | só `jenkins.cursodetecnologia.dev.br` |

Rodar o **mesmo** ID em duas máquinas não dá erro — e é por isso que é
perigoso. O Cloudflare trata as duas como **réplicas** e **divide o tráfego**:
metade das requisições vai para uma, metade para a outra, e a metade que cair
na máquina errada dá 502 sem nada no log parecer errado.

---

## ⚠️ O `cert.pem` NÃO foi para a VM, e não deve ir

Existem dois segredos aqui, e eles têm poderes muito diferentes:

| Arquivo | Onde está | O que autoriza |
|---|---|---|
| `cert.pem` | **só na estação** (`~/.cloudflared/`) | criar túneis, criar/apagar **DNS da zona inteira** |
| `f0d7cd68….json` | `/etc/cloudflared/` na VM, modo 600, dono root | **rodar aquele túnel**, e nada mais |

Por isso o túnel foi criado **na estação** e só o JSON viajou. Quem invadir a
VM ganha a capacidade de servir aquele hostname; não ganha o seu domínio.

---

## ⚠️ A ordem importa: Access ANTES do DNS

O `jenkins` desta máquina está nos grupos `docker` e `microk8s` — na prática,
**root ali**. Quem passar da tela de login não ganha "o Jenkins": ganha a
máquina que roda os dez projetos, inclusive o urupix, que movimenta dinheiro
de terceiro.

Então o registro DNS é o **último** passo, e não o primeiro. Criá-lo antes do
Access abriria uma janela — de minutos ou de dias — com a tela de login do
Jenkins exposta na internet, e essa janela é exatamente o que varredores
automáticos encontram.

### ✅ RESOLVIDO por nginx com senha, e não por Cloudflare Access

**O Access foi descartado por custo de cadastro.** A tela de plano do Zero
Trust pede **cartão de crédito** mesmo no Free (`Due today $0/month`, com o
cartão arquivado). É genuinamente grátis para 1 assento de 50 — mas não vale
cadastrar cartão por um CI de casa.

No lugar dele: **nginx com autenticação básica** na VM, dentro do túnel que já
existia. O que se queria é concreto — que varredor automático não ache uma tela
de login de CI exposta — e uma senha antes da aplicação resolve isso.

```
internet → Cloudflare → túnel → nginx :8081 (SENHA) → Jenkins :8080
```

| | |
|---|---|
| Usuário | `samuel` |
| Senha | gerada com `openssl rand`, hash **bcrypt** em `/etc/nginx/jenkins.htpasswd` |
| nginx escuta | **só** `127.0.0.1:8081` |
| Jenkins escuta | **só** `127.0.0.1:8080` |

**Provado pela internet:** sem senha → `401` com página genérica do nginx, que
**não revela que há Jenkins atrás**. Com senha → `200`, `<title>Sign in -
Jenkins</title>`.

⚠️ **`http://192.168.15.55:8080` não responde mais**, nem de dentro de casa.
Se precisar sem passar pelo túnel:

```bash
ssh -L 8080:127.0.0.1:8080 usuario@192.168.15.55
```

#### 🐞 Três armadilhas que essa montagem cobrou

**1. O nginx repassa o `Authorization` para cima.** Com a senha correta o
Jenkins devolvia `401` assim mesmo: ele recebia o cabeçalho e tentava
autenticar `samuel` como usuário *dele*. A senha era lida duas vezes, por dois
sistemas diferentes, e o segundo não a conhece. Resolve com
`proxy_set_header Authorization "";` — a barreira do nginx já cumpriu o papel,
e daqui para cima a requisição tem que subir limpa.

**2. Dois `401` parecendo o mesmo.** O do nginx e o do Jenkins só se
distinguiam pelo `WWW-Authenticate`: `realm="Jenkins"` (nginx) contra
`realm="Jenkins", charset="UTF-8"` (Jenkins). Batizar o realm do nginx de
"Jenkins" foi erro meu; hoje ele é `serverhomol - acesso externo`.

**3. `systemctl reload` não derruba socket.** Depois de remover o site padrão,
o nginx continuava escutando em `0.0.0.0:80` com os processos antigos. Só o
`restart` fechou.

**4. 🐞 A URL raiz do Jenkins ficou apontando para o endereço antigo — e o
sintoma foi "não consigo logar".**

`jenkins.model.JenkinsLocationConfiguration.xml` guardava
`http://192.168.15.54:8080/` — endereço errado (`.54` é o notebook, a VM é
`.55`), em `http`, e que deixou de responder quando fechei o `bind`.

O Jenkins **validava a senha corretamente** e então mandava o navegador para
aquele endereço morto. Da cadeira de quem usa, isso é indistinguível de senha
recusada — e leva a pessoa a duvidar da própria senha, que é o pior lugar para
procurar.

Corrigido para `https://jenkins.cursodetecnologia.dev.br/`. Depois disso o POST
de login redireciona para `/loginError` — **relativo**, no próprio domínio.

⚠️ **Sempre que o endereço de acesso do Jenkins mudar, este arquivo tem que
mudar junto.** Ele não é derivado da requisição; é configuração, e envelhece
calado.

---

## Duas senhas, e elas são de camadas diferentes

Isto confunde, e vale ter escrito:

| Ordem | Quem pergunta | Usuário | O que é |
|---|---|---|---|
| 1ª | **nginx** (caixa do navegador) | `samuel` | a barreira que criei, para o mundo não chegar no Jenkins |
| 2ª | **Jenkins** (página com formulário) | `samuca` ou `marcia` | a conta de verdade, que já existia |

Digitar a conta do Jenkins na **primeira** caixa não funciona: o nginx não a
conhece, e o navegador só repergunta — parecendo login recusado.

---

### ~~1. Criar a aplicação no Zero Trust~~ *(não foi este o caminho)*

**one.dash.cloudflare.com → Access → Applications → Add an application →
Self-hosted**

| Campo | Valor |
|---|---|
| Application name | `Jenkins serverhomol` |
| Session duration | 24 horas |
| Subdomain / Domain | `jenkins` / `cursodetecnologia.dev.br` |

Política: **Allow**, regra **Emails** → `samucationx@gmail.com`.

### 2. O DNS — **já criado**, e travado em 404

O registro existe desde 20/08/2026. O hostname **não entrega o Jenkins**: a
regra do túnel devolve `http_status:404` para todo mundo. Assim o mapeamento
está pronto sem que a tela de login fique exposta enquanto o Access não sobe.

Conferido de fora: `404`, corpo vazio, sem menção a Jenkins.

Para **ligar**, depois que a aplicação do Access existir, troque em
`/etc/cloudflared/config.yml`:

```yaml
  - hostname: jenkins.cursodetecnologia.dev.br
    service: http://127.0.0.1:8080     # era http_status:404
```

```bash
sudo cloudflared tunnel ingress validate && sudo systemctl restart cloudflared
```

#### 🐞 `tunnel route dns <nome>` ignorou o nome que eu passei

O comando abaixo criou o CNAME apontando para o túnel **errado**:

```powershell
cloudflared tunnel route dns serverhomol jenkins.cursodetecnologia.dev.br
# INF Added CNAME ... will route to this tunnel tunnelID=47a05dc3...  <- nerdquiz!
```

Ele leu o `tunnel:` do `~/.cloudflared/config.yml` da estação em vez de usar o
nome do argumento. E **não avisou** — a mensagem de sucesso traz o ID errado no
meio, que é fácil de não ler.

Aqui não houve estrago porque o `nerdquiz` não tem regra para `jenkins` e o
catch-all dele é `http_status:404`. Num túnel com catch-all diferente, o
hostname teria começado a servir a aplicação errada.

O jeito que funciona é isolar o config e passar o **UUID**:

```powershell
cloudflared --config <config-minimo-com-o-uuid-certo> tunnel route dns `
    --overwrite-dns f0d7cd68-27da-4686-b826-4ce1d3a9243f jenkins.cursodetecnologia.dev.br
```

⚠️ **Confira sempre o `tunnelID=` na saída.** É a única confirmação de para
onde o registro foi mesmo.

### 3. E só então, fechar o `bind` do Jenkins

Enquanto o caminho de fora não funciona, prender o Jenkins no `127.0.0.1`
deixaria você sem acesso nenhum. Depois que funcionar:

```bash
# /etc/default/jenkins  ou  o override do systemd
JENKINS_LISTEN_ADDRESS=127.0.0.1
```

Hoje ele escuta em `*:8080` — **qualquer aparelho da rede**, inclusive um
convidado no Wi-Fi, alcança a tela de login.

---

## Conferir

```bash
# na VM
systemctl status cloudflared
sudo journalctl -u cloudflared -f | grep -E 'Registered|ERR'
```

Quatro `Registered tunnel connection` é o normal — o Cloudflare mantém quatro
conexões para não depender de uma só.

⚠️ **Se o Access estiver certo, `curl` sem credencial NÃO deve devolver a tela
do Jenkins.** Devolve um redirecionamento para o login do Cloudflare. Se vier
`<title>Jenkins</title>`, o Access não está na frente — apague o DNS na hora.

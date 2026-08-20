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

### 1. Criar a aplicação no Zero Trust *(precisa da sua conta)*

**one.dash.cloudflare.com → Access → Applications → Add an application →
Self-hosted**

| Campo | Valor |
|---|---|
| Application name | `Jenkins serverhomol` |
| Session duration | 24 horas |
| Subdomain / Domain | `jenkins` / `cursodetecnologia.dev.br` |

Política: **Allow**, regra **Emails** → `samucationx@gmail.com`.

### 2. Só então, o DNS

```powershell
cloudflared tunnel route dns serverhomol jenkins.cursodetecnologia.dev.br
```

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

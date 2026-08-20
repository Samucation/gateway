# Rede e infraestrutura — problemas conhecidos

Catálogo de problemas de **rede** que já custaram tempo aqui, e dos que a
gente sabe que virão. Cada um tem o **sintoma** (o que você vê), a **causa** e
o **conserto**.

> Escrito porque o ambiente é uma rede doméstica com máquina virtual, notebook
> que dorme e IP por DHCP. Esses problemas voltam.

---

## 1. O `ping` do Windows MENTE sobre "0% de perda"

**Sintoma**

```
Reply from 192.168.15.9: Destination host unreachable.
Packets: Sent = 3, Received = 3, Lost = 0 (0% loss)
```

Você lê "0% loss" e conclui que o host responde. **Ele não responde.**

**Causa.** As respostas vêm da **sua própria máquina** (repare no IP), dizendo
que não conseguiu entregar. O `ping` do Windows conta essas mensagens de erro
ICMP como "recebidas", e a estatística final fica verde.

**Conserto.** Ler as **linhas**, nunca só a estatística. A resposta boa vem do
IP de destino e traz `TTL=`:

```
Reply from 192.168.15.54: bytes=32 time=3ms TTL=64     ← esta é de verdade
Reply from 192.168.15.9:  Destination host unreachable ← esta é erro
```

**Custou** ~20 minutos em 19/08/2026, investigando firewall de uma máquina que
simplesmente não existia naquele endereço.

---

## 2. ARP incompleto = não há ninguém ali

**Sintoma.** `Get-NetNeighbor` devolve `00-00-00-00-00-00` com estado
`Incomplete`, ou `arp -a` diz `No ARP Entries Found`.

**Causa.** Ninguém na rede local respondeu "eu sou esse IP".

**Por que é o teste decisivo.** ARP é camada 2 e **não passa por firewall**. Se
o ARP não resolve, o endereço não existe na rede — não adianta procurar porta
fechada, regra de firewall ou serviço parado.

```powershell
ping -n 1 <IP>; arp -a <IP>
```

---

## 3. VM do VMware em modo NAT é invisível da rede

**Sintoma.** Dentro da VM, `ip a` mostra algo como `192.168.138.129`. De outra
máquina da casa, esse endereço não responde a nada.

**Causa.** A faixa `192.168.138.x` é a rede NAT interna do VMware. Ela existe
só dentro daquele host. É um ramal: vale dentro da empresa, não de fora.

**Conserto.** `VM → Settings → Network Adapter → Bridged`.

⚠️ **Evite NAT + redirecionamento de porta** para servir Kubernetes. Você
precisaria de uma regra por porta (6443, 80, 443, Jenkins, Kong…), e o k3s se
incomoda com endereço que não é o dele — certificado e `advertise-address` são
emitidos para o IP que o nó vê de si mesmo.

---

## 4. Ponte por Wi-Fi: a VM usa o MAC do HOST

**Sintoma.** A VM funciona, mas ao procurá-la na rede pelo fabricante do MAC
não se acha nenhum `00:0C:29` / `00:50:56` (VMware). Em vez disso, **dois IPs
diferentes aparecem com o MESMO MAC** — o do notebook.

```
192.168.15.20    C8-8A-9A-7C-62-12     ← o notebook
192.168.15.54    C8-8A-9A-7C-62-12     ← a VM, com o MAC dele
```

**Causa.** O ponto de acesso só aceita quadros do MAC que se autenticou. O
VMware contorna traduzindo o endereço — a VM sai com o MAC do host.

**Por que importa.** Funciona, mas é frágil:

- **cai quando o notebook dorme**, troca de rede ou reconecta;
- o sintoma é a VM sumir da rede **sem nada nos logs dela**;
- procurar a VM pelo MAC de VMware **não a encontra** — e foi assim que ela
  passou despercebida numa varredura aqui.

**Conserto.** Passar o host para **cabo**. Na Ethernet a VM usa o MAC próprio e
tudo se comporta como máquina física.

---

## 5. ⚠️ Trocar Wi-Fi → cabo MUDA o IP (e pode quebrar o k3s)

**Este é o que ainda vai acontecer.**

**Causa em dois passos.** No cabo a VM passa a usar o **MAC dela**, não o do
host. MAC diferente = **concessão DHCP nova** = provavelmente **outro IP**.

⚠️ Continuar na mesma faixa `192.168.15.x` **não basta** — o que importa é o
mesmo **endereço**.

**Por que quebra o k3s.** O k3s emite o certificado TLS dele para o **IP do nó
no momento da instalação**. Se o IP mudar depois:

- o `kubectl` recusa a conexão por certificado inválido;
- o erro fala de certificado, e **ninguém liga isso a "troquei o cabo"**.

**As duas defesas — usar as duas:**

1. **Fixar o endereço**, por reserva de DHCP no roteador (por MAC) ou IP
   estático no Ubuntu (`/etc/netplan/`). Como o MAC muda ao ir para o cabo, o
   ideal é **passar para o cabo primeiro** e só então fixar.

2. **Instalar o k3s com `--tls-san`**, incluindo um NOME além do IP:

   ```bash
   curl -sfL https://get.k3s.io | sh -s - --tls-san hmg.veltrixa.local --tls-san <IP>
   ```

   Com o nome no certificado, trocar o IP deixa de invalidar tudo — basta
   apontar o nome para o endereço novo.

**Se já tiver acontecido**, dá para consertar sem reinstalar:

```bash
sudo systemctl stop k3s
sudo rm -f /var/lib/rancher/k3s/server/tls/dynamic-cert.json
sudo systemctl start k3s          # ele reemite os certificados
```

E atualizar o `server:` no `~/.kube/config` para o IP novo.

---

## 5b. ACONTECEU: o certificado do kubelet ficou com o IP antigo

**Confirmado em 19/08/2026**, e antes do previsto — foi a troca de NAT para
ponte que disparou, nao a de Wi-Fi para cabo. A causa e a mesma: **o IP mudou
depois da instalacao**.

**Sintoma.** Tudo parece bem (`kubectl get pods` funciona, os Pods sobem), mas
qualquer comando que fale com o **kubelet** falha:

```
kubectl exec -n veltrixa veltrixa-postgres-0 -- psql ...
  error: tls: failed to verify certificate:
  x509: certificate is valid for 192.168.138.129, not 192.168.15.54
```

Afeta `exec`, `logs -f`, `port-forward` e `top` — tudo que passa pela porta
10250. E confunde porque **o resto do cluster funciona**: o certificado do API
server o MicroK8s renova sozinho; o do kubelet, nao.

**Diagnostico — qual certificado ficou para tras:**

```bash
for c in /var/snap/microk8s/current/certs/*.crt; do
  ips=$(sudo openssl x509 -in "$c" -noout -text | grep -o "IP Address:[0-9.]*" | tr "
" " ")
  echo "$(basename $c): $ips"
done
```

⚠️ `microk8s refresh-certs` **nao serve**: ele so aceita `ca.crt`,
`server.crt` e `front-proxy-client.crt`. O do kubelet e reemitido a mao.

**Conserto** (guarde o antigo antes):

```bash
C=/var/snap/microk8s/current/certs
sudo cp $C/kubelet.crt $C/kubelet.crt.bak
IP=$(hostname -I | awk '{print $1}')

sudo bash -c "cat > /tmp/kubelet-csr.conf <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn
[dn]
CN = 127.0.0.1
[req_ext]
subjectAltName = @alt
[alt]
DNS.1 = $(hostname)
DNS.2 = localhost
IP.1 = 127.0.0.1
IP.2 = $IP
EOF"

sudo openssl req -new -key $C/kubelet.key -out /tmp/kubelet.csr -config /tmp/kubelet-csr.conf
sudo openssl x509 -req -in /tmp/kubelet.csr -CA $C/ca.crt -CAkey $C/ca.key -CAcreateserial   -out $C/kubelet.crt -days 3650 -extensions req_ext -extfile /tmp/kubelet-csr.conf

sudo microk8s stop && sudo microk8s start
```

**O detalhe que evita a proxima vez:** incluir o **nome da maquina**
(`DNS.1 = $(hostname)`) no certificado. Com o nome dentro, trocar o IP deixa de
invalidar — e foi por isso que o conserto acima poe `serverhomol` junto.

Conferir o que o kubelet REALMENTE serve (nao o que esta no arquivo):

```bash
echo | openssl s_client -connect <IP>:10250 2>/dev/null | openssl x509 -noout -text | grep -A1 Alternative
```

---

## 5c. ACONTECEU: a VM caiu e o HOSPEDEIRO passou a responder no IP dela

**Confirmado em 19/08/2026**, no meio de um trabalho. O sintoma foi:

```
ssh: connect to host 192.168.15.54 port 22: Connection refused
```

E o mais enganoso: **o ping continuava respondendo**.

```
Reply from 192.168.15.54: bytes=32 time=3ms TTL=128
arp  192.168.15.54  ->  c8-8a-9a-7c-62-12   (resolve normalmente)
Test-NetConnection porta 22 -> False
```

Lido pela metade, isso parece "o SSH caiu". Não é.

**A pista é o TTL.** A VM sempre respondeu `TTL=64` (Linux). Aquele `TTL=128` é
**Windows** — quem estava atendendo o ping era o NOTEBOOK, não a VM. O Ubuntu
não estava rodando.

Faz sentido com o item 4: em ponte por Wi-Fi a VM sai com o MAC do host, e com
ela suspensa o próprio host responde por aquele endereço. O ARP resolve, o ping
responde, e nada disso significa que a máquina virtual existe.

**Conserto.** Ligar a VM no VMware. Nada a fazer na rede.

**A lição de método:** `ping` + `arp` respondendo NÃO provam que o host certo
está vivo. Uma linha a mais — o TTL — separa "está no ar" de "outra coisa está
no ar no lugar dele". É o teste mais barato do catálogo e o que mais rende.

---

## 6. TTL diz qual sistema respondeu

Conferência barata, antes de qualquer conexão:

| TTL na resposta | Sistema |
|---|---|
| 64 | Linux / Unix |
| 128 | Windows |
| 255 | equipamento de rede |

`TTL=64` num IP onde você esperava o Ubuntu já confirma que é ele.

---

## 7. Um dígito a mais

`192.168.15.154` em vez de `192.168.15.54` custou uma investigação inteira de
firewall, ponte e serviço parado.

**Antes de investigar acesso, confirme o endereço** — de dentro da máquina:

```bash
ip -4 addr show          # o endereço REAL da interface
hostname -I              # todos, em uma linha
```

E confira que o que você digitou é o que apareceu ali.

---

## Ordem de diagnóstico (do mais barato ao mais caro)

Quando "não consigo acessar a máquina", siga nesta ordem — cada passo elimina
uma classe inteira:

1. **`ip -4 addr` DENTRO da máquina** — o endereço é o que você pensa?
2. **`ping` + ler as LINHAS** — a resposta vem do IP certo, com `TTL`?
3. **ARP** — resolve? Se não, não há ninguém ali (item 2)
4. **porta TCP** — `cat < /dev/null > /dev/tcp/IP/22`
5. **só agora**: firewall, serviço parado, chave SSH

Os quatro primeiros levam segundos e resolvem a maioria dos casos. Começar pelo
firewall é o caminho mais longo — e foi por onde a gente começou em 19/08/2026.

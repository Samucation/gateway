# ⚠️ A VM troca de IP sozinha — e isso quebra o cluster

A `serverhomol` está em **DHCP** (`/etc/netplan/00-installer-config.yaml`,
`dhcp4: true`) e o roteador vem alternando o endereço dela.

Observado em 21/08/2026, em **menos de duas horas**:

```
192.168.15.55  →  192.168.15.56  →  192.168.15.55
```

Sem reiniciar. A máquina ficou de pé o tempo todo — só a concessão mudou.

---

## Por que isso não é um incômodo pequeno

**Quebra o `kubectl exec` e o `kubectl logs` no cluster inteiro.** O certificado
do kubelet lista os IPs válidos; quando o nó muda de endereço, o servidor de API
tenta falar com um IP que não está no certificado:

```
tls: failed to verify certificate: x509: certificate is valid for
127.0.0.1, 192.168.15.55, not 192.168.15.56
```

E o sintoma é enganoso: os Pods continuam rodando e servindo, tudo parece bem —
até alguém precisar ver um log ou entrar num contêiner, justamente quando há um
problema para investigar.

**E quebra qualquer script que fixe o endereço** — inclusive todos os que
existem neste repositório.

---

## O que já foi feito (mitigação, não correção)

O certificado agora cobre **os dois** endereços observados. Em
`certs/csr.conf.template`:

```
IP.1 = 127.0.0.1
IP.2 = 10.152.183.1
IP.3 = 192.168.15.55
IP.4 = 192.168.15.56
```

⚠️ Isso **não resolve**: cobre só os dois endereços já vistos. No dia em que o
roteador entregar um terceiro, quebra igual.

### Como refazer o certificado, se voltar a quebrar

```bash
C=/var/snap/microk8s/current/certs
sudo cp $C/csr.conf.template $C/csr.conf
sudo openssl req -new -key $C/kubelet.key -out /tmp/k.csr -config $C/csr.conf
sudo openssl x509 -req -in /tmp/k.csr -CA $C/ca.crt -CAkey $C/ca.key \
  -CAcreateserial -out $C/kubelet.crt -days 365 \
  -extensions v3_ext -extfile $C/csr.conf
sudo chown root:microk8s $C/kubelet.crt && sudo chmod 660 $C/kubelet.crt
sudo systemctl restart snap.microk8s.daemon-kubelite
```

🐞 **Acrescentar IPs no fim do arquivo não funciona.** Eles têm que entrar na
seção `[alt_names]`; fora dela o openssl recusa com
`error in extension: section=v3_ext, name=IP.5`. O gabarito já tem o lugar
certo — use-o inteiro em vez de anexar linhas.

⚠️ E `microk8s refresh-certs -e server.crt` **não** refaz o `kubelet.crt`. Ele
regenera outro certificado e o problema continua, o que engana.

---

## A correção de verdade: reserva de DHCP no roteador

No painel do roteador, atrelar o **MAC da VM** a um IP fixo — preferencialmente
`192.168.15.55`, que é o que os scripts deste repositório usam.

```bash
# o MAC, para cadastrar:
ip link show | grep -A1 "state UP" | grep link/ether
```

Um IP estático no `netplan` também resolveria, mas tem risco: se o endereço
escolhido estiver dentro da faixa que o roteador distribui, outro aparelho pode
recebê-lo e criar conflito. A reserva evita isso porque é o próprio roteador
quem passa a garantir o endereço.

---

## Como saber se é isto, da próxima vez

O teste que separa "a VM caiu" de "a VM mudou de IP":

```bash
# o túnel é uma conexão de SAÍDA — funciona qualquer que seja o IP da LAN
curl -s -o /dev/null -w '%{http_code}' https://jenkins.cursodetecnologia.dev.br/login
```

**401 quer dizer que a máquina está viva** e o problema é o endereço. Então:

```powershell
# varre a faixa procurando quem responde SSH
foreach ($n in 2..130) { ... ConnectAsync($ip, 22) ... }
```

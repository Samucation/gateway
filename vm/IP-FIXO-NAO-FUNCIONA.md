# ⛔ IP fixo na VM NÃO funciona — e o motivo não é o que parece

Tentado em 22/08/2026, duas vezes, com reversão automática armada. Produção não
sofreu. **A conclusão é que o conserto não é na VM.**

## O que foi tentado

Trocar `ens33` de DHCP para `192.168.15.240/24` fixo, via netplan. O endereço
`.240` foi escolhido depois de varrer a rede: de `.2` a `.60` há quatro
aparelhos; de `.200` a `.254`, nenhum.

## O que aconteceu

Por dentro da VM, funcionou perfeitamente:

    ens33  inet 192.168.15.240/24
    State: routable (configured)
    Online state: online

**De fora, a VM ficou inalcançável.** Sete minutos de sondagem contínua da
estação, sem uma única resposta em `.240`.

## Por que

A pista está no ARP. A estação vê o endereço da VM assim:

    192.168.15.56    c8-8a-9a-7c-62-12

E a VM diz que a placa dela é:

    link/ether 00:0c:29:81:18:ed    (OUI 00:0c:29 = VMware)

**Os dois não batem.** Há um aparelho entre a estação e a VM respondendo ARP no
lugar dela — ponte com tradução de MAC. É o que VMware faz quando a máquina
hospedeira entra na rede por **Wi-Fi**: o 802.11 não deixa uma estação emitir
quadros com MAC de terceiro, então a ponte reescreve o endereço e mantém uma
tabela.

⚠️ **E essa tabela é aprendida pela conversa de DHCP.** Com IP fixo não há
conversa: a ponte nunca fica sabendo que `.240` é da VM, e o tráfego de entrada
não chega. O de saída funciona — foi por isso que o túnel continuou de pé e
produção não caiu durante os testes.

Isso explica, junto, os três sintomas que pareciam soltos:

- funciona por dentro, não por fora;
- o endereço do DHCP sempre funciona;
- a VM "muda de IP sozinha" (`.54` → `.55` → `.56`) — cada renovação de lease
  pode trazer número novo, e a ponte reaprende.

## O conserto de verdade

**Reserva de DHCP no roteador.** É o único jeito de o endereço parar de mudar
sem quebrar a ponte, porque a conversa de DHCP continua acontecendo — só que
sempre com a mesma resposta.

⚠️ Ao cadastrar, conferir **qual MAC o roteador enxerga**. Se ele vir
`c8:8a:9a:7c:62:12` (o da ponte) em vez de `00:0c:29:81:18:ed` (o da VM), a
reserva precisa ser feita pelo que ele vê — e aí ela pode prender o aparelho
errado, se a ponte fizer isso para mais de uma máquina.

A alternativa, se a reserva não for possível: **ligar a máquina hospedeira por
cabo** em vez de Wi-Fi. Com cabo, a ponte não precisa reescrever MAC, e IP fixo
na VM passa a funcionar.

## O remendo que ficou no lugar

Enquanto isso, o que segura:

- `estacao/k3d-hmg.yaml` lista **quatro endereços** no espelho de registro
  (`.56`, `.55`, `.54`, `.57`) — o containerd tenta em ordem;
- `vm/achar-vm.ps1` varre a rede e **confere o nome da máquina** antes de
  devolver o endereço;
- `vm/conferir-deriva-de-tag.ps1` usa esse localizador em vez de número fixo.

## Os scripts da tentativa

`vm/fixar-ip.sh` e `vm/diagnosticar-ip.sh` ficam versionados. Eles funcionam —
o problema não é o roteiro, é a rede. Se a hospedeira passar para cabo, basta
rodar o primeiro.

⚠️ Os dois armam **reversão automática** antes de mexer: em N segundos, se
ninguém criar `/tmp/ip-confirmado`, a configuração antiga volta sozinha. Foi
isso que permitiu testar duas vezes numa máquina que roda produção, cujo único
acesso é o SSH que passa pela rede sendo alterada. Sem essa rede de segurança, a
primeira tentativa teria deixado a VM inalcançável — e não haveria como entrar
para desfazer.

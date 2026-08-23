# Produção nesta estação, **fora do Docker**

> Estado: **fundação pronta**. As aplicações ainda não foram migradas — a
> produção que está no ar hoje continua sendo a de Docker Compose.

---

## O pedido, e por que ele inverte o que existia

Do Samuel, em 23/08/2026:

> *"eu gostaria que o desenvolvimento e hmg fosse o ambiente docker e o prd o
> ambiente não docker aqui nessa maquina, pois assim eu queria poder desligar
> tudo que é do docker quando fosse usar o computador e mesmo assim ainda ter o
> ambiente todo em pé"*

⚠️ Hoje é o contrário, e pior do que parece: **homologação também é Docker**.
O k3d roda *dentro* de contêineres do Docker Desktop. Fechar o Docker derruba
os dois ambientes de uma vez.

| | antes | depois |
|---|---|---|
| dev | Docker Compose | Docker Compose |
| hmg | k3d (dentro do Docker) | k3d (dentro do Docker) |
| **prd** | **Docker Compose** | **k3s na distro WSL2 `prd`** |

---

## Por que k3s em WSL2, e não uma VM nem serviços nativos

**VM local** (VMware/Hyper-V) funcionaria e é o arranjo que já conhecíamos da
`serverhomol`. Duas desvantagens decidiram contra: reserva RAM fixa o tempo
todo, e **não repassa CUDA**.

**Serviços nativos do Windows** seria o mais "não Docker" de todos, e o mais
caro: jogaria fora os manifestos, os overlays `prd` dos oito sistemas e o
estágio `Implantar em producao` da esteira. Cada sistema viraria um caso à
parte.

**k3s em WSL2** ganha nos quatro pontos que importam:

1. **Independente do Docker Desktop** — containerd próprio, dentro da distro.
2. **Aproveita tudo** — os overlays `prd` e a esteira funcionam sem alteração.
3. **Repassa a GPU.** É o que a VM nunca conseguiu. Hoje a voz do urupix em
   produção depende desta estação estar com o Docker de pé — exatamente o que
   se quer poder desligar.
4. **Memória elástica**, em vez de um bloco reservado.

---

## O que já está de pé

```
distro    prd            Ubuntu 26.04 LTS, systemd ligado
k3s       v1.36.3+k3s1   nó `prd` Ready
ingress   traefik        classe padrão
registro  registry:2     localhost:32000, volume de 40Gi
```

⚠️ **O Traefik foi removido e recolocado.** A instalação começou com
`--disable=traefik`, por hábito da VM. Errado: **todos** os manifestos dos
projetos declaram `ingressClassName: traefik`. Sem ele os `Ingress` ficam sem
controlador e o sintoma é **404** — que parece rota errada e é ausência de
quem roteia.

⚠️ **O registro precisa se chamar `localhost:32000`.** É o nome que os
overlays usam, herdado do addon do MicroK8s. Mudá-lo obrigaria a reescrever a
imagem em nove repositórios — e aí a esteira publicaria num lugar e o cluster
procuraria em outro. Por isso `hostPort`, e não `NodePort`: de dentro da
distro, `localhost` tem que ser o registro.

---

## 🐞 A descoberta de rede que decide o corte

O encaminhamento de `localhost` do WSL2 **só funciona num sentido** nesta
máquina:

```
de dentro da distro → localhost:32000  ✅ 200
do Windows          → localhost:32000  ❌ falha
do Windows          → 172.29.89.49:32000 (IP da distro)  ✅ 200
```

Isso importa porque **o túnel do Cloudflare roda no Windows** e precisa
alcançar o Traefik lá dentro. Apontá-lo para `localhost` não vai funcionar.

E há um detalhe que engana: dentro da distro, `127.0.0.1:5432`, `:5452`,
`:5455`… **já respondem** — são os Postgres do Docker Desktop, publicados no
Windows e espelhados para cá. Ou seja, `localhost:5432` de dentro da distro
**não é** o banco da distro. Confundir os dois num arquivo de configuração
daria "conectou, mas no banco errado", que é o pior tipo de acerto.

Dois caminhos para resolver, e a escolha fica para a hora do corte:

- **`netsh interface portproxy`** no Windows, apontando `localhost:PORTA` para
  o IP da distro, atualizado pela mesma tarefa que sobe o WSL no boot. Não
  mexe na rede do Docker.
- **`networkingMode=mirrored`** no `.wslconfig`. Resolve nos dois sentidos e é
  mais limpo, mas exige `wsl --shutdown` — que derruba **todas** as distros,
  inclusive a do Docker onde a produção está agora.

---

## 🐞 `.wslconfig`: duas chaves que nunca estiveram valendo

O WSL 2.7 recusa `autoMemoryReclaim` e `sparseVhd` sob `[wsl2]` — elas moram
em `[experimental]`. A recusa sai como um aviso fácil de não ver
(`Unknown key`) e a execução segue normalmente.

Estavam no lugar errado desde 13/08/2026. Quer dizer: **a devolução de memória
ociosa que o arquivo descrevia nunca esteve ligada**. Corrigido.

O teto subiu de 20 GB para 32 GB, e o motivo é medido: as distros do WSL
dividem **uma** máquina virtual e **um** teto. Com o Docker de pé, sobravam
4 GB para a produção nova — ela não caberia. Depois da virada o Docker fica
desligado a maior parte do tempo, e o consumo real cai para o do k3s sozinho
(~16 GB, medido na `serverhomol` com 59 Pods).

---

## O que falta

1. **Ferramenta de construção sem Docker.** Conferido: os 13 `Dockerfile` dos
   oito sistemas de produção **não** usam recursos de BuildKit — `buildah` ou
   `nerdctl` dão conta. (Quem usa são o `quiz-game`, que segue em Docker, e o
   `sigma-payments`, aposentado.)
2. **Subir um sistema inteiro** e provar o caminho antes de tocar no urupix,
   que é o que tem dinheiro dentro.
3. **Migrar os dados** dos contêineres Docker para os volumes do k3s.
4. **O corte do túnel**, com o encaminhamento de porta resolvido.
5. **Autostart no boot + vigia.** ⚠️ WSL2 **não sobe sozinho**: sem uma tarefa
   na inicialização, um reinício deixa a produção no chão em silêncio. E
   `wsl --shutdown` derruba todas as distros — falta medir se alguma ação do
   Docker Desktop dispara isso.
6. **Provar com um reinício de verdade.** Enquanto isso não for feito, o
   arranjo não pode ser chamado de produção.

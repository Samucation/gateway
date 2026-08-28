# Rancher — o painel dos clusters

> Instalado em **28/08/2026**, primeiro na homologação desta estação.
>
> Este documento é o runbook: como alcançar, por que as escolhas são estas, e
> **como montar num ambiente novo** — que foi o pedido que originou tudo.

---

## 1. O que é, e por que passou a existir

Até 28/08/2026 não havia painel nenhum: todo diagnóstico de cluster era
`kubectl` na mão. Perguntas comuns — qual Pod está reiniciando, qual PVC ficou
`Pending`, o que o contêiner falou antes de morrer — custavam três comandos
cada.

⚠️ O custo não é o comando. É **ninguém olhar por causa dele**. As dívidas deste
projeto que mais demoraram a aparecer (o espelho apontando para uma VM
desligada, o Keycloak com 40 reinícios em 42 horas, o Jenkins quatro dias em
404) têm em comum não terem sido vistas, e não serem difíceis.

---

## 2. Onde ele está

| | |
|---|---|
| Cluster | **homologação** (`k3d-hmg`), namespace `cattle-system` |
| Nome interno | `rancher.hmg` — mesmo padrão de `sonar.hmg` |
| Entrada | Traefik do k3d, na **8090** da estação |
| Réplicas | 1 |
| Consumo medido | **652 MiB** (reserva 1 GiB, teto 2 GiB) |
| Manifesto | `estacao/rancher-hmg.yaml` |
| Instalador | `estacao/instalar-rancher.ps1` |

### Como abrir

```powershell
# pelo cabeçalho Host, sem mexer em nada:
curl.exe -H "Host: rancher.hmg" http://127.0.0.1:8090/

# ou, para abrir no navegador, acrescente ao arquivo hosts do Windows
# (C:\Windows\System32\drivers\etc\hosts, precisa de Administrador):
127.0.0.1 rancher.hmg
# e abra  http://rancher.hmg:8090/
```

Usuário `admin`. A senha inicial foi gerada na instalação e está em
`%USERPROFILE%\.rancher-senha-hmg.txt` — **fora do repositório**, de propósito.

---

## 3. ⚠️ O custo, medido e não estimado

As distros do WSL2 **dividem uma máquina virtual e um teto** (`memory=40GB` no
`.wslconfig`). A produção mora na distro `prd`; o k3d de homologação mora no
Docker Desktop. **Os dois saem do mesmo bolo.**

Então o Rancher não é "de graça porque é homologação": ele tira memória de um
limite que a produção compartilha. Se um dia faltar, o caminho é o que o
`.wslconfig` já manda — **enxugar contêiner**, e não subir o teto até encostar
no físico.

Foi por isso que ele subiu com **teto explícito de 2 GiB**. O que já derrubou
esta máquina foi contêiner sem teto: o Redpanda do Veltrixa sozinho segurava
2,3 GiB. Um painel administrativo não podia ser o próximo.

---

## 4. As três armadilhas que esta instalação cobrou

### 🐞 1. `tls: external` não faz o Rancher falar HTTP

Ele **continua exigindo HTTPS** e delega a prova disso à camada da frente,
olhando o cabeçalho `X-Forwarded-Proto`. Não vendo `https`, devolve:

    302  →  https://rancher.hmg/

um endereço sem porta e sem TLS. O navegador segue o desvio e morre em "não foi
possível conectar".

⚠️ **O Ingress está certo nesse momento** — sem anotação de redirecionamento,
`ssl-redirect: "false"`, backend na porta 80. Quem redireciona é a aplicação,
não a entrada. `kubectl get ingress -o yaml` vem limpo e não aponta para nada,
o que manda procurar no Traefik, onde não há o que achar.

A saída é um `Middleware` do Traefik que injeta o cabeçalho — está no
manifesto, com o nome no formato `<namespace>-<nome>@kubernetescrd`. Escrito
curto (só `<nome>`), o Traefik não encontra a referência e devolve **500** na
rota, o que parece o Rancher fora do ar.

### 🐞 2. `replicas` padrão é 3, e este cluster tem um nó

As outras duas ficariam em `Pending` para sempre por antiafinidade, e o painel
apareceria como "instalação incompleta" sem nada de errado.

### 🐞 3. O `HelmChart` tem de ser declarado em `kube-system`

O controlador `helm.cattle.io` do k3s **só observa objetos no namespace dele**.
Declarado em `cattle-system`, o objeto é aceito pela API e **nunca processado**:
`kubectl get helmchart` mostra ele lá, e nada acontece.

---

## 5. Rancher em ambiente novo

Este é o pedido que originou o documento: que montar o próximo ambiente **já
saia configurado**.

```powershell
# 1. o cluster tem de existir e responder
kubectl --context <contexto> get --raw /readyz

# 2. instalar
.\estacao\instalar-rancher.ps1 -Contexto <contexto>
```

O script cuida de: namespace, senha inicial (Secret, **não** no YAML), aplicação
do manifesto, as duas esperas (Job do Helm → Deployment) e a **prova pela
entrada** — que não é a mesma coisa que `rollout status` verde.

### 🔴 O que MUDA fora do loopback: o TLS

O `estacao/rancher-hmg.yaml` traz `tls: external` **e** um Middleware que
afirma `X-Forwarded-Proto: https` numa requisição que chegou por HTTP.

Isso só é aceitável aqui porque o caminho inteiro é
navegador → `127.0.0.1:8090` → Docker → contêiner do nó: **nenhum salto de
rede**. Em qualquer outro ambiente essa afirmação passa a ser mentira, e a
senha do painel que administra o cluster atravessaria o fio em claro.

Para um ambiente de verdade, troque no `valuesContent`:

```yaml
    # em vez de `tls: external` + Middleware:
    ingress:
      ingressClassName: traefik
      tls:
        source: secret          # certificado real, que você já tem
```

e crie o Secret `tls-rancher-ingress` no `cattle-system` com o par
certificado/chave. A alternativa `source: rancher` traz o **cert-manager**
junto (mais ~300 MB e três CRDs) para emitir um autoassinado que o navegador
recusa de qualquer jeito — custo sem proteção, a menos que você já use
cert-manager para outra coisa.

⚠️ Com TLS de verdade, **remova o Middleware `proto-https`**. Ele deixa de ser
necessário (o `X-Forwarded-Proto` passa a ser verdadeiro) e passa a ser um
lugar onde a origem da requisição pode ser forjada.

### ⚠️ E a ordem, que já custou caro nesta casa

O Rancher pede um ServiceAccount com poder de **cluster inteiro**. Ensaiar isso
primeiro num cluster descartável é a diferença entre "deu errado, recria" e
"deu errado no que move dinheiro". Foi por isso que ele entrou pela
homologação, e é por isso que o `instalar-rancher.ps1` **recusa** rodar quando o
nome do contexto diz `k3d-` e o nó não é de k3d.

Essa guarda existe porque o irmão dela faltou antes: em 21/08/2026 as esteiras
aplicaram `overlays/hmg` no cluster que naquele dia tinha virado produção, e o
Ingress do Urupix voltou de `urupix.com.br` para `urupix.hmg` — domínio público
em 404 com a aplicação de pé.

---

## 6. O que ele NÃO resolve

- **Não é backup.** Ver `estacao/backup-estacao.ps1`.
- **Não vigia sozinho.** Ele mostra; alguém tem de olhar. O que avisa sem
  ninguém pedir continua sendo o painel do Jenkins e os watchdogs.
- **Não gerencia a produção ainda.** Está só na homologação. Apontá-lo para o
  k3s da distro `prd` é uma decisão separada, com o custo de memória a ser
  medido de novo — e é onde a escolha de TLS da seção 5 passa a valer.

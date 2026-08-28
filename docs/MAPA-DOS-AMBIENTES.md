# Mapa dos ambientes — leia isto ANTES de investigar

> Este documento existe para você **não precisar redescobrir a topologia** toda
> vez que algo quebra. Ele responde três perguntas: **o que roda onde**, **o que
> nunca mexer**, e **o que conferir primeiro**.
>
> Atualizado em 22/08/2026.

---

## 1. O que roda onde

> ⚠️ **MUDOU EM 24/08/2026.** A VM `serverhomol` foi desligada e a produção
> passou para esta estação, **fora do Docker**. O que está abaixo é o arranjo
> de hoje; o anterior está no fim desta seção, porque a VM continua sendo a
> volta se algo aqui der errado.

| | **PRODUÇÃO** | **HOMOLOGAÇÃO** | **DESENVOLVIMENTO** |
|---|---|---|---|
| Onde | distro WSL2 `prd` (disco em `G:`) | k3d, dentro do Docker Desktop | Docker Compose |
| Orquestrador | k3s | k3d (`k3d-hmg`) | — |
| Entrada | **Kong** (Pod, `hostPort` 80 e 8050) | Traefik na 8090 | Kong na 8050 |
| Como o Windows alcança | `netsh portproxy` → IP da distro | direto | direto |
| Túnel | serviço `NerdQuizTunnel` (Windows) | serviço `Cloudflared` | — |
| Registro de imagens | `localhost:32000`, **dentro do k3s** | **próprio**, Docker :32001 (dados em `G:`) | — |
| Construtor | `nerdctl` + buildkit (**sem Docker**) | Docker | Docker |
| Jenkins | serviço do systemd na distro, 1 executor, **preso em `127.0.0.1:8080`**; quem vem de fora passa pelo nginx `:8081`, que pede SENHA | — | — |
| SonarQube | Pod no cluster, em `sonar.hmg` | — | — |
| Rancher | — | Pod em `cattle-system`, em `rancher.hmg` (8090) | — |

⚠️ **O Docker é ambiente de trabalho, não de produção.** Fechá-lo derruba
homologação e desenvolvimento — e a produção continua de pé. Era esse o
objetivo do arranjo.

### Como a HOMOLOGAÇÃO está montada (24/08/2026)

Ela existe de novo, e é um cluster **de verdade separado** — não o mesmo com
outro nome:

```
   produção      k3s   na distro WSL2 `prd`     kubeconfig padrão
   homologação   k3d   no Docker Desktop        --kubeconfig ~/.kube/config-hmg
```

47 Pods, os 9 projetos, cada um com o **seu** banco. A entrada é o Traefik do
k3d, publicado pelo Docker na `8090` da máquina — e é por lá que a esteira
verifica, com o cabeçalho `Host` de cada domínio `*.hmg`.

> ⚠️ **REMONTADO EM 28/08/2026, e portanto VAZIO.** O contêiner
> `k3d-hmg-server-0` tinha sido apagado — sobrara só o `serverlb`, em laço de
> reinício, com `host not found in upstream "k3d-hmg-server-0:6443"`. Volume e
> rede também já não existiam: o cluster foi recriado do zero por
> `estacao/montar-hmg.ps1`.
>
> Ele tem hoje os **9 namespaces, o RBAC, os segredos, a classe de disco e o
> Traefik** — mas **nenhuma aplicação**. Os 47 Pods voltam conforme cada
> esteira rodar; quem implanta é a esteira, nunca `kubectl apply -k` à mão (ver
> o item 2 deste documento).
>
> 🐞 E a remontagem **falhava no último passo** até este dia: o
> `montar-hmg.ps1` criava **oito** namespaces, enquanto o
> `jenkins-rbac-hmg.yaml` e o `segredos-hmg.ps1` já assumiam **nove**. O nono
> (`sigma-payments`) morria em `falhou ao aplicar sigma-payments-secrets`,
> depois de 95% do cluster montado — e a mensagem mandava procurar no SEGREDO,
> quando a causa era o namespace que nunca foi criado, dois passos antes.
> As três listas agora concordam; mudou uma, confira as outras duas.

**Fechar o Docker derruba a homologação inteira, e a produção não sente.** Era
esse o objetivo do arranjo.

#### As duas coisas que precisaram existir para religar

1. **Um registro de imagens só dela** (Docker, `:32001`). O registro da produção
   vive *dentro* da distro WSL2, e contêiner do Docker **não tem rota até lá** —
   medido: de um contêiner, `ping` na distro perde 100% dos pacotes. As duas
   distros do WSL só se encontram através de porta publicada no host Windows.
   A esteira publica na produção e **espelha** para cá.

   ⚠️ Os dados ficam em `G:\docker-registro-hmg`, e não em volume do Docker: o
   `C:` já chegou a 0 GB nesta máquina e derrubou tudo. Custo: as imagens ficam
   em duplicidade. Para limpar:
   `docker exec registro-hmg registry garbage-collect /etc/docker/registry/config.yml`

2. **A variável `HMG_CONTEXTO`**, que liga as três etapas de homologação das
   esteiras. Elas estavam desligadas desde 21/08 por uma guarda **certa**:
   naquele dia a estação virou produção, as esteiras continuaram aplicando
   `overlays/hmg` no cluster que agora era produção, e às 20:48 o Ingress do
   Urupix voltou de `urupix.com.br` para `urupix.hmg` — domínio público em 404
   com a aplicação de pé.

   O `vm/hmg-religado.groovy` religa, mas **confere antes** que o nó do outro
   lado não é o mesmo da produção. Se for, recusa e explica.

⚠️ **O espelho do k3d apontava para os quatro IPs da VM desligada.** A
homologação não conseguia baixar imagem nova — e não aparecia, porque os Pods
seguiam no ar com o que já estava no nó, e a próxima implantação nunca chegava
(as etapas estavam desligadas). Dois defeitos se escondendo um atrás do outro.

### Como o tráfego entra hoje (24/08/2026)

```
cloudflared (Windows, serviço NerdQuizTunnel)
   └─ 127.0.0.1:8050
        └─ netsh portproxy  →  <IP da distro>:80
             └─ KONG (Pod em gateway/, hostPort 80 e 8050)
                  ├─ host declarado  →  Service do projeto, direto
                  └─ host NÃO declarado  →  Traefik (ClusterIP) → Ingress
```

Entre 23 e 24/08/2026 o Kong ficou **fora do caminho**: quem atendia era o
Traefik. Todos os domínios respondiam, e por isso ninguém percebeu o que tinha
sumido junto — `correlation-id`, teto de requisições, o CORS de cada projeto e
as métricas do Prometheus. **Gateway que não está no caminho não protege nada,
e “o site abre” não é evidência de que ele está.**

A prova de que um domínio passa mesmo pelo Kong é o cabeçalho
`X-Request-Id` na resposta. Sem ele, ou o host não está declarado (caiu na
reserva) ou o Kong não está na entrada:

```bash
curl -sI https://urupix.cursodetecnologia.dev.br/ | grep -i x-request-id
```

Conferência completa, host a host:

```bash
wsl -d prd -u root -- bash /mnt/e/.../gateway/estacao/prd-wsl/conferir-kong.sh
```

⚠️ **O Traefik não saiu de cena.** Ele deixou de ocupar a porta 80 do nó
(virou `ClusterIP`) e passou a ser chamado pelo Kong. Quem não está no
`kong.yml` — veltrixa, ninjasystem, sprinklegames, `sigma-midia-arquivos`,
`sonar.hmg` — continua sendo atendido por ele, pela rota de reserva.

⚠️ **Exceção: o NerdQuiz.** `quiz` e `api` nunca ganharam manifesto de
Kubernetes; seguem em Docker. Pará-los derruba esses dois domínios.

⚠️ **Exceção: a pilha de GPU.** Kokoro, Chatterbox, Whisper e Ollama são
contêineres Docker soltos — sem manifesto.

Isso **não é regressão**: na VM eles também ficavam de fora, porque o VMware
não repassa CUDA. Ficar em Docker é a mesma situação de antes.

O que MUDOU é que agora daria para trazê-los: conferido em 24/08/2026, o
`/dev/dxg` e o `libcuda.so` existem dentro da distro `prd` — o WSL2 repassa a
GPU. Levá-los para o cluster é o que tornaria a produção **de fato**
independente do Docker, e exige quatro manifestos novos, acesso a `/dev/dxg`
nos Pods e migrar os volumes de modelo (o do Ollama sozinho passa de 2 GB).

Enquanto não for feito: **fechar o Docker desliga a voz sintetizada e a
transcrição**, e o resto da produção continua de pé.

### O arranjo anterior, para quem precisar da volta

| | **PRODUÇÃO (até 23/08)** | **HOMOLOGAÇÃO** |
|---|---|---|
| Máquina | VM `serverhomol` | esta estação |
| Orquestrador | MicroK8s | k3d |
| Jenkins | na VM | — |

**Nove sistemas**, os dois ambientes: `urupix` (live-flow), `sprinklegames`,
`opuschat`, `plataforma` (cafe-mobile-erp), `veltrixa` (system-api),
`sigma-financeiro`, `sigma-midia`, `central-ia`, `sigma-payments`.

⚠️ **A IA de GPU fica FORA da VM** (Kokoro, Chatterbox, Whisper, Ollama). O
VMware não repassa CUDA. Eles rodam nesta estação, em Docker, e o túnel de
produção devolve para cá o que precisa deles. O mesmo vale para o **NerdQuiz**
(`quiz` e `api`), que nunca foi migrado.

### Os dois nomes de homologação, e por que ambos existem

    <projeto>-hmg.cursodetecnologia.dev.br   público — testar de qualquer lugar
    <projeto>.hmg                            interno — a esteira confere por aqui

O `-hmg` no domínio é a proteção mais barata contra o erro mais caro: abrir a
aba errada e mexer em produção achando que é teste.

O interno existe para a verificação da esteira **não depender do túnel**. Se ela
usasse o domínio público, uma queda de túnel apareceria como "o deploy falhou".


### As duas telas do Jenkins

Todo projeto aqui é *multibranch*: na tela inicial aparece a **pasta**, e o job
de verdade (`main`) está um clique adentro. Com dez projetos, saber o estado
geral custava dez cliques — e é por isso que ninguém olhava.

    https://jenkins.cursodetecnologia.dev.br/view/Painel/
    https://jenkins.cursodetecnologia.dev.br/view/Todas%20as%20esteiras/

O **Painel** é mural: cada esteira é um cartão colorido, com a barra de
progresso de quem está construindo. Serve para deixar aberto numa aba.

**Todas as esteiras** é a lista, com última execução, duração e tendência.

⚠️ As duas filtram por `.*/main$` — o nome COMPLETO do job multibranch. Filtrar
só por `main` não casa com nada. E como é regex, **projeto novo entra sozinho**.

### O painel próprio, e o portão de produção nele

    https://jenkins.cursodetecnologia.dev.br/userContent/painel/painel.html

Fonte em `vm/painel/`. Lê a cada 10 s e mostra, por cartão, a fase atual, a
porcentagem, e botões de reenviar e parar.

🔴 **O estado que importa é `ESPERANDO SUA APROVAÇÃO`** — cartão amarelo,
piscando, com aviso de sistema que **não some sozinho**. É o único momento em
que a esteira depende de uma pessoa, e tem prazo: passados 60 minutos sem
resposta, o Jenkins aborta a execução depois de todo o trabalho já feito.

⚠️ Ao aprovar pela API, `proceed` **não é opcional** e a falta dele não dá
erro: o `InputStepExecution.doSubmit` vai pelo caminho da REJEIÇÃO e ainda
responde **200**. O valor é o rótulo do botão (`ok:` do passo `input`):

    curl -X POST -u <user>:<token> -H "$CRUMB" \
      --data-urlencode 'proceed=Promover' \
      --data-urlencode 'json={"parameter":[{"name":"ACAO","value":"Promover"}]}' \
      "$JENKINS/job/<projeto>/job/main/lastBuild/input/<id>/submit"

Uma build já foi morta assim, com quem apertava achando que estava aprovando.

---

## 2. O que NUNCA mexer

### 🔴 O Kong é UM SÓ

**Jamais criar um Kong novo.** Existiam cinco (um por projeto, 4,75 GB somados)
e o Docker caía por pressão de memória derrubando o Urupix no meio de live. Em
14/08/2026 viraram um só, no projeto `gateway`.

Consequências que já morderam:

- o Kong **por projeto** não existe mais. Qualquer configuração que aponte para
  `kong:8001` de dentro de um namespace vai encontrar um `ExternalName` para o
  compartilhado — ou nada, em homologação, que não tem gateway;
- o compartilhado sobe com **`KONG_ADMIN_LISTEN=off`**. Painéis administrativos
  que falavam com a API de administração estão mortos por desenho;
- em homologação **não há gateway nenhum**. Ainda.

### 🔴 O `sigma-financeiro` é de leitura

Consultar pode; alterar código, não. A exceção liberada cobre `k8s/` e o
`Dockerfile` (duas linhas, em 22/08/2026, autorizadas). Nada de rota, campo,
migração ou regra de negócio.

### 🔴 Não aplicar overlay de homologação à mão

    kubectl apply -k k8s/overlays/hmg     ← NÃO

⚠️ Isto reverte a tag da imagem para o valor guardado no Git, e esse valor
costuma estar velho — a esteira reescreve a linha no espaço de trabalho dela e
nunca devolve ao repositório. Em 22/08/2026 derrubei quatro serviços assim, em
sequência, **depois** de ter documentado a armadilha.

Quem implanta é a esteira. Ela é a única que sabe qual tag acabou de construir.

---

## 3. O que conferir primeiro, por sintoma

### “O domínio devolve 502”

Meça **por dentro da VM** antes de suspeitar da aplicação:

    ssh usuario@<vm> 'curl -s -o /dev/null -w "%{http_code}\n" -H "Host: urupix.com.br" http://127.0.0.1/'

- **200 por dentro e 502 por fora** → é CPU. O `cloudflared` não está sendo
  atendido. `uptime` responde mais rápido que qualquer log. Já aconteceu com
  `load average 40` em 8 núcleos;
- **erro por dentro também** → aí sim é a aplicação.

### “O domínio devolve 404 do Traefik”

O Ingress não reconhece o host. Não é aplicação fora do ar — é rota faltando:

    kubectl get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"  "}{.spec.rules[*].host}{"\n"}{end}'

Compare com o que o túnel declara. O túnel costuma estar na frente.

### “ImagePullBackOff”

Quase nunca é a imagem. Nesta ordem:

1. **A tag do overlay está velha?** (a armadilha do item 2 acima);
2. **A imagem baixa mesmo?** `docker push` sair com zero não prova nada —
   conferir manifesto **e blobs**:

       curl -s -H "Accept: application/vnd.oci.image.manifest.v1+json" \
            http://<registro>/v2/<nome>/manifests/<tag>

   Se vier um **índice** (`"manifests"`), os atestados do BuildKit voltaram e o
   manifesto da plataforma some. Falta `--provenance=false --sbom=false`;
3. **O espelho aponta para o endereço certo?** A VM está em DHCP e já mudou de
   IP três vezes.

### “Pod `Running` mas `0/1`”

A probe está recusando. Chame-a **de dentro do Pod** — 401 costuma significar
rota fora da lista de liberadas, não serviço quebrado.

### “Não consigo mais acessar o Jenkins”

⚠️ **Confira o serviço e a ROTA separados.** Em 28/08/2026 o Jenkins passou
quatro dias inalcançável estando **perfeitamente de pé** — respondendo `200` em
`http://127.0.0.1:8080/login` o tempo todo. Serviço de pé não é evidência de
serviço alcançável, e confundir os dois foi o que custou o tempo.

```bash
wsl -d prd -u root -- bash -c "tr -d '\r' < /mnt/e/.../prd-wsl/estado-do-jenkins.sh > /tmp/e.sh; bash /tmp/e.sh"
```

As duas causas encontradas, independentes uma da outra:

1. **O acesso público nunca veio pelo túnel `nerdquiz`.** Vinha de um túnel
   PRÓPRIO, o `serverhomol`, que rodava **na VM**. A VM foi desligada em 24/08,
   o Jenkins foi reinstalado aqui, e a rota não. O pedido passou a chegar no
   `nerdquiz`, não casou com regra nenhuma e morreu no `http_status:404`.

   ⚠️ O sintoma é **404 limpo**, e não 502 nem 1033 — o que faz parecer
   "endereço errado" em vez de "rota faltando". `cloudflared tunnel list`
   mostrando **0 conexões** num túnel é o sinal de que ele morreu com a máquina
   dele.

2. **O acesso local dependia de um `portproxy` que ninguém refazia.** Ver a
   dívida logo abaixo — é a mais grave das duas, e não é sobre o Jenkins.

Hoje o caminho é:

```
internet → Cloudflare → túnel nerdquiz → 127.0.0.1:8081 (portproxy)
                                          → nginx na distro (SENHA)
                                             → Jenkins 127.0.0.1:8080
```

⚠️ **São duas senhas, de camadas diferentes.** A 1ª é a do nginx (caixa do
navegador, usuário `samuel`); a 2ª é a conta do Jenkins (`samuca`). Digitar a
segunda na primeira caixa não funciona: o navegador só repergunta, parecendo
login recusado.

### “A esteira está verde mas nada mudou”

As quatro causas já vistas, todas silenciosas:

- **atestados** — imagem no registro, impossível de baixar;
- **guarda com contexto errado** — aplicou no cluster errado;
- **`-DskipTests`** — o teste nunca rodou;
- **`kubectl apply` sem espera** — ele devolve zero quando o cluster **aceita
  a intenção**, não quando a versão nova sobe. Um Pod em `CrashLoopBackOff`
  passava por promoção bem-sucedida. Desde 22/08/2026 o estágio de produção
  espera o `rollout status` de todo deployment e statefulset do namespace.

Rode `python ferramentas/conferir-esteiras.py`: ele varre os 11 repositórios
procurando exatamente isso.

### “O portão de qualidade acusa 0% de cobertura, com a suíte passando”

O Sonar lê o arquivo apontado por `sonar.javascript.lcov.reportPaths`, que é
`coverage/lcov.info`. **Relatório ausente não vira reclamação: vira zero.**

⚠️ Os relatórios padrão do `@vitest/coverage-v8` são `text`, `html`, `clover` e
`json` — **`lcov` não está entre eles**. Um projeto que não o declare
explicitamente entrega cobertura real de 80% e aparece com 0,0% no portão.

Aconteceu no `sigma-financeiro` em 22/08/2026, com 902 testes passando. O
número errado é caro porque é plausível: leva a escrever teste para código já
testado. Confira antes de acreditar:

```bash
ls -l coverage/lcov.info && grep -c '^SF:' coverage/lcov.info
```

Arquivo **ausente do lcov** também conta como 0% — não só arquivo com linhas
descobertas. Componentes de tela que nenhum teste importa entram nessa conta.

### “O portão exige revisão de *security hotspot*”

A condição `new_security_hotspots_reviewed = 100%` **não pode ser satisfeita
por esteira nenhuma**: hotspot é revisado por uma pessoa na tela do Sonar, que
marca cada um como seguro ou a corrigir. Enquanto ninguém revisar, o portão
reprova — e o log da esteira não diz isso com todas as letras.

⚠️ O token da esteira **não tem permissão** para listar hotspots pela API
(`Insufficient privileges`), então nem dá para saber quais são sem entrar na
tela.

### “O teste em Dart morre com `LateInitializationError`”

Leia **as linhas de cima**. A causa costuma ser:

```
Failed to load dynamic library 'libsqlite3.so'
```

O `LateInitializationError: Local 'db' has not been initialized` é o erro do
`tearDown` — o `setUp` já tinha morrido. Lido de cima para baixo, o log acusa
teste mal escrito, e o conserto “natural” seria mexer no teste, que está certo.

A imagem oficial `dart:3.12` não traz a biblioteca. ⚠️ E instalar
`libsqlite3-0` **não basta**: o pacote entrega `libsqlite3.so.0`, com a versão
no nome, e o Dart procura `libsqlite3.so` sem versão — os testes continuam
falhando com a mesma mensagem, o que convida a concluir que o pacote não
adiantou. O `TESTES_DART` em `ferramentas/estagios.py` instala o pacote **e**
cria o atalho.

### “O Keycloak fica reiniciando”

Olhe o motivo do término, não só o log:

```bash
kubectl get pod -n <ns> <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
```

`OOMKilled` na partida é teto de memória, não instabilidade. ⚠️ Sem
`--optimized`, a partida roda **duas JVMs** — a que recompila a configuração e
a do servidor — e cada uma toma até 70% da memória do contêiner para heap.

Em homologação o sintoma é `CrashLoopBackOff`; em produção ele **sobe depois de
várias tentativas**, e aí parece instabilidade do Keycloak. Foi assim que
passou despercebido por 42 horas no `veltrixa`, com 40 reinícios.

A correção está no `system-api`: `JAVA_OPTS_APPEND` com `MaxRAMPercentage=50` e
teto de 1,5 Gi, mantendo `requests` em 512Mi — o pico dura segundos e reservar
1,5 Gi tiraria memória do cluster inteiro o tempo todo.

### “O nginx não sobe”

Ele **resolve os nomes dos destinos na partida** e recusa iniciar se um faltar
— derrubando a interface inteira por causa de um destino acessório. A saída é
passar o destino por variável, com `resolver`, o que adia a resolução para o
momento do pedido.

⚠️ Duas armadilhas ao fazer isso: o arquivo precisa ir para
`/etc/nginx/templates/*.template` (só ali passa o envsubst), e
`NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1` é **opt-in** — sem ela, a variável do
resolvedor nunca é calculada e a mensagem culpa o resolvedor.

---

## 4. As guardas que já existem

Nenhuma delas é opcional; todas nasceram de um estrago real.

| guarda | o que pega |
|---|---|
| `ferramentas/conferir-esteiras.py` | esteira sem atestados desligados, sem guarda de contexto, ou sem conferência de push |
| `vm/conferir-deriva-de-tag.ps1` | o overlay de `prd` declarando tag diferente da que está no ar |
| `scripts/conferir-ambiente.mjs` | defesa de Kong mais fraca depois da consolidação |
| `scripts/conferir-plugins.mjs` | plugin efetivo diferente do Kong de origem |
| guarda de **carga** no `Preparo` | build começando com a máquina afogada |
| guarda de **disco** no `Preparo` | build começando sem espaço (piso absoluto, 12 GB) |
| conferência de **push** em cada esteira | imagem publicada que não baixa |

---

## 5. Dívidas conhecidas

| o quê | onde está escrito |
|---|---|
| 🔴 **A produção não sobe sozinha no boot** | este documento, logo abaixo |
| ⚠️ O túnel de produção está **sem vigia** | `NerdQuizTunnelWatchdog` está `Disabled` |
| VM em DHCP, muda de IP sozinha | `vm/IP-OSCILANDO.md`, `vm/IP-FIXO-NAO-FUNCIONA.md` |
| Homologação **sem gateway** | este documento, item 2 |
| Produção e CI no mesmo ferro | `vm/MUDAR-PARA-LINUX-NATIVO.md` |
| Chave SSH pessoal no Jenkins | `vm/DIVIDA-SEGURANCA.md` |
| Registros de DNS mortos | `vm/DNS-A-APAGAR.md` |
| `sempre-mais-barato` sem nenhum commit | — |

### 🔴 A tarefa `ProducaoWSL` não existe nesta máquina

Medido em **28/08/2026**: `Get-ScheduledTask -TaskName ProducaoWSL` não devolve
nada, e a tabela de `portproxy` tinha só `80` e `8050` — faltavam a `8081`
(Jenkins) e a `32000` (registro).

O `estacao/prd-wsl/subir-no-boot.ps1` existe, está correto, e **nunca foi
instalado** (ou foi removido). O cabeçalho dele já avisa o que isso significa:

> Sem esta tarefa, um reinício deixa a produção no chão **em silêncio**: os
> domínios respondem 530, o Windows está normal, e nada no Visualizador de
> Eventos aponta para a causa.

⚠️ A distro está de pé hoje porque alguém a subiu à mão. **Não sobrevive ao
próximo reinício.** Conserto (PowerShell **como Administrador**):

```powershell
.\estacao\prd-wsl\religar-acesso-jenkins.ps1
```

Ele instala a tarefa, aplica o encaminhamento de portas agora, valida e
reinicia o túnel, e **prova pela internet** que o Jenkins voltou atrás da senha.

---

## 6. Onde o resto está escrito

O detalhe de cada armadilha mora **no ponto exato onde ela morde**, em
comentário no próprio arquivo — é lá que alguém vai estar quando o problema
voltar. Este mapa é o índice, não o substituto.

    gateway/vm/README.md              a VM, o túnel, o corte
    gateway/docs/rede-problemas-conhecidos.md
    gateway/docs/inversao-prd-hmg.md  como prd e hmg trocaram de lugar
    <projeto>/k8s/overlays/*/         cada overlay explica o próprio ambiente
    <projeto>/Jenkinsfile             cada estágio explica o que já quebrou nele

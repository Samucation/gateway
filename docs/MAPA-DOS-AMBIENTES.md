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
| Entrada | Traefik na porta 80 | Traefik na 8090 | Kong na 8050 |
| Como o Windows alcança | `netsh portproxy` → IP da distro | direto | direto |
| Túnel | serviço `NerdQuizTunnel` (Windows) | serviço `Cloudflared` | — |
| Registro de imagens | `localhost:32000`, **dentro do k3s** | espelha do prd | — |
| Construtor | `nerdctl` + buildkit (**sem Docker**) | Docker | Docker |
| Jenkins | serviço do systemd na distro, 1 executor | — | — |
| SonarQube | Pod no cluster, em `sonar.hmg` | — | — |

⚠️ **O Docker é ambiente de trabalho, não de produção.** Fechá-lo derruba
homologação e desenvolvimento — e a produção continua de pé. Era esse o
objetivo do arranjo.

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
| VM em DHCP, muda de IP sozinha | `vm/IP-OSCILANDO.md`, `vm/IP-FIXO-NAO-FUNCIONA.md` |
| Homologação **sem gateway** | este documento, item 2 |
| Produção e CI no mesmo ferro | `vm/MUDAR-PARA-LINUX-NATIVO.md` |
| Chave SSH pessoal no Jenkins | `vm/DIVIDA-SEGURANCA.md` |
| Registros de DNS mortos | `vm/DNS-A-APAGAR.md` |
| `sempre-mais-barato` sem nenhum commit | — |

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

# Mapa dos ambientes — leia isto ANTES de investigar

> Este documento existe para você **não precisar redescobrir a topologia** toda
> vez que algo quebra. Ele responde três perguntas: **o que roda onde**, **o que
> nunca mexer**, e **o que conferir primeiro**.
>
> Atualizado em 22/08/2026.

---

## 1. O que roda onde

| | **PRODUÇÃO** | **HOMOLOGAÇÃO** |
|---|---|---|
| Máquina | VM `serverhomol` | esta estação de trabalho |
| Orquestrador | MicroK8s | k3d (`k3d-hmg`) |
| Entrada | Traefik na porta 80 | Traefik na porta 8090 |
| Túnel | serviço `cloudflared` na VM | serviço `Cloudflared` no Windows |
| Domínios | `<projeto>.cursodetecnologia.dev.br` | `<projeto>-hmg.…` **e** `<projeto>.hmg` |
| Registro de imagens | `:32000` na VM (usado pelos DOIS) | espelhado de lá |
| Jenkins | na VM, **1 executor** | — |

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

As três causas já vistas, todas silenciosas:

- **atestados** — imagem no registro, impossível de baixar;
- **guarda com contexto errado** — aplicou no cluster errado;
- **`-DskipTests`** — o teste nunca rodou.

Rode `python ferramentas/conferir-esteiras.py`: ele varre os 11 repositórios
procurando exatamente isso.

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

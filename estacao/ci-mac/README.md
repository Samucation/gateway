# Agente de CI no MacBook

Como o trabalho de build passou a ser dividido entre a estação e o MacBook da
rede — e, principalmente, **o que não deu certo**, porque é isso que evita
repetir.

## O problema que motivou

Medido em 06/09/2026, no meio de um dia normal:

```
rodando : sigma-payments #6 (Sonar)
na fila : gateway #48, system-api #31, live-flow #85
          "Waiting for next available executor"  ×3
I/O da distro de produção: 31% de estol (avg300)
```

**Um executor, doze esteiras** — e a máquina que paga o build é a mesma que
serve os domínios. O próprio Jenkinsfile do cartório já carregava a nota de que
*"dois builds em paralelo derrubaram a máquina virtual inteira"*.

## O desenho

Três metades, e a do meio existe por medição, não por preferência:

| estágio | agente | o que faz |
|---|---|---|
| `CI` | `params.AGENTE_CI` | preparo, testes, Sonar, portão |
| `IMAGEM` | `built-in` **sempre** | construir e publicar imagem |
| `CD` | `built-in` **sempre** | implantar no cluster |

`AGENTE_CI` nasce com **`mac-arm || built-in`**: o Jenkins escolhe quem estiver
livre. Com o MacBook dormindo ou fora da rede, a build cai no built-in e nada
para. **A máquina local é a rede de segurança, e isso foi provado com o Mac
offline.**

## ⚠️ Por que a imagem NÃO vai para o Mac

O cluster é amd64; o Mac é arm64. Construir imagem lá significa emular tudo que
o Dockerfile roda (`mvn package`, `npm ci`, `apt-get`). Medido em 07/09/2026:

```
cartório, 3 imagens .... 6189s (103 min)  e FALHOU
sigma-payments ......... 5281s ( 88 min)  e FALHOU

ERROR: failed to connect to the docker API at
       unix:///Users/.../.orbstack/run/docker.sock
```

**Não é só lentidão: a emulação prolongada derrubou o daemon do Docker do Mac,
duas vezes.** Depois da segunda o próprio Mac ficou inalcançável.

O ganho real está nos testes: o CI do cartório caiu de **441s para 240s** no Mac.

### O caminho para um dia levar a imagem também

Compilar o artefato **nativo** (arm64, rápido) e montar a imagem amd64 só com
`COPY`, sem nenhum `RUN` — aí não há o que emular. JAR é independente de
arquitetura, então serve para os projetos Java. Exige mexer nos Dockerfiles.
O `4saas/Dockerfile` já tem um estágio `runtime-prebuilt` com essa forma.

## 🐞 Armadilhas que custaram caro

### Testar com uma ferramenta e concluir sobre outra

Aconteceu três vezes num dia:

- `curl`, da **mesma imagem** e para o **mesmo endereço**, devolvia 200 enquanto
  o scanner do Sonar (Java) morria em `ConnectException: null`. `curl` usa
  conexão bloqueante e atravessa o repasse de loopback do OrbStack; o cliente
  HTTP do Java usa conexão assíncrona e não atravessa.
- `docker pull --platform linux/arm64` devolveu *"up to date"* deixando a imagem
  **amd64** — a imagem não tem variante arm64.
- `timeout` **não existe no macOS**: os testes "com teto de tempo" saíam em
  `command not found` **com código 0**, sem testar nada.

### Cache envenenado não acusa

Um `alpine:3` **amd64** ficou no cache do Mac (sobra de um teste com
`--platform`). Todo `docker run alpine:3` posterior rodava emulado. Um `rm -rf`
de quatro diretórios travou a build por 58 minutos. O único sinal era o
`WARNING` de plataforma, perdido no log.

> **Regra:** contêiner **ferramenta** roda nativo no agente. Só a imagem final
> da aplicação precisa casar com a arquitetura do cluster.

### `agent none` quebra coisas silenciosamente

- A **TAG**: o bloco `environment` pode ser avaliado antes do checkout,
  `GIT_COMMIT` vir nulo, e a TAG cair para `local`. As imagens sairiam
  `<projeto>:local`, o deploy aplicaria `:local` — **e a esteira ficaria verde**.
- O **`post`**: os `sh` de limpeza precisam de nó e derrubam a build inteira
  *depois* de todos os estágios reais terem passado. `node('')` **não** é a
  saída: ele disputa a fila depois da build e trava as outras esteiras.

### A ordem dos estágios decide se a migração existe

Os testes eram inseridos **depois** do `Construir`, o que os prendia dentro de
`IMAGEM` (built-in). Só o `Preparo` iria para o Mac. **A esteira ficaria verde e
pareceria migrada, sem estar.**

### Regenerar apaga correção feita à mão

`live-flow` (`PROMOVER_AUTO`) e `opuschat` (promoção direta) têm correções que o
gerador não conhece — e ele **avisa isso no cabeçalho**. Regenerei sem ler e
apaguei as duas. Consertei à mão, regenerei de novo, e apaguei de novo.

Por isso esses dois passam por `aplicar-split.py`, que transforma por texto,
preserva o resto e é idempotente.

## Infraestrutura

**Túnel reverso** (`tunel-registro.service`), iniciado da estação para o Mac:

```
-R 32000:localhost:32000    registro
-R  8050:localhost:8050     gateway (Sonar)
```

Sem `sshd` na `prd`, sem nada exposto na LAN, e o endereço visto no Mac é
`localhost:32000` — **o mesmo que os manifestos já usam**.

⚠️ `ExitOnForwardFailure=yes` não é detalhe: sem ele o ssh conecta, falha o
encaminhamento e **fica vivo** — serviço `active` com túnel morto.

## Pendências

1. **O Mac dorme.** Enquanto dormir, não recebe trabalho. Precisa de
   `caffeinate` ou ajuste em Economia de Energia.
2. **Cabo de rede.** Medido: roteador 0,51ms, MacBook 89,6ms (máx 227ms) — é
   Wi-Fi com economia de energia. O protocolo do agente Jenkins é conversador.
3. **Merge dos branches `ci-no-mac`** — é ato de implantar, decisão humana.

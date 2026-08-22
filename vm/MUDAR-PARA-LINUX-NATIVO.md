# Levar a produção para uma máquina Linux nativa

O que existe hoje: **VMware Workstation** rodando Ubuntu com MicroK8s, 59 Pods,
77 GB usados de 116 GB, 14 GB de RAM em uso.

O que se quer: a mesma coisa em **hardware nativo**, sem reinstalar tudo.

---

## A pergunta que decide o caminho

> Dá para pegar a imagem da VM e simplesmente bootar no hardware novo?

**Dá, e é o caminho mais barato** — mas com uma ressalva que precisa ser dita
antes: converter disco de VM para hardware físico (o chamado *V2P*) é a operação
com **mais partes móveis** das três abaixo. Ela move junto tudo o que você quer
(dados, configuração, certificados, imagens) e também tudo o que você não quer
(drivers da VMware, UUID de disco antigo, nomes de interface de rede).

Por isso este documento apresenta **três caminhos**, do mais fiel ao mais limpo.

---

## Caminho A — clonar o disco inteiro (V2P)

Converte o `.vmdk` num disco real e dá boot.

    # na estação, com a VM DESLIGADA
    qemu-img convert -p -O raw serverhomol.vmdk serverhomol.raw
    # gravar no disco da máquina nova (via live USB)
    dd if=serverhomol.raw of=/dev/nvme0n1 bs=64M status=progress conv=fsync

**Ganha:** tudo. Dados, imagens do containerd, certificados, Jenkins com
histórico, tokens, cron, tudo exatamente como está.

⚠️ **Três coisas quebram, e todas de forma que engana:**

1. **O nome da interface de rede muda.** O Ubuntu nomeia por caminho de
   hardware: na VM é `ens33`; no hardware novo será `enp5s0` ou parecido. O
   netplan referencia o nome antigo, a máquina sobe **sem rede**, e você
   descobre isso sem conseguir entrar por SSH para consertar. **Precisa de
   teclado e monitor no primeiro boot.**

2. **O disco tem outro UUID.** O `/etc/fstab` e o carregador de boot apontam
   para o UUID antigo. Sintoma: para no `initramfs` com "cannot find root".
   Conserta-se de dentro do live USB.

3. **Os módulos da VMware ficam no initramfs.** Não impede o boot, mas atrasa e
   polui o log. `update-initramfs -u` depois de subir.

**Quando escolher:** quando o objetivo é continuidade máxima e você aceita uma
madrugada com teclado e monitor ligados na máquina nova.

---

## Caminho B — máquina nova limpa + restaurar os dados (RECOMENDADO)

Instalar Ubuntu do zero, instalar MicroK8s, e trazer só o que importa.

**Por que eu recomendo este**, apesar de dar mais trabalho na aparência:

⚠️ Metade do que existe na VM hoje foi construído **corrigindo defeito atrás de
defeito**, e boa parte já está descrita em arquivo neste repositório — o cluster
se remonta a partir do Git. O que NÃO está no Git é só o dado e o segredo, e
esses têm procedimento próprio e testado.

⚠️ E há um ganho que o caminho A não dá: a VM carrega 23 GB de imagens no
containerd, muitas de builds antigos que ninguém usa. Máquina nova começa
limpa.

### O que precisa ir junto (e só isso)

| o quê | como | já existe? |
|---|---|---|
| Os 11 bancos | `vm/migrar-dados.ps1` | ✅ testado hoje |
| Mídia (banco + objetos) | `vm/migrar-midia.ps1` | ✅ testado hoje |
| Segredos do urupix | `live-flow/k8s/prd-segredos.ps1` | ✅ |
| Segredos do sigma | `vm/sigma-segredos-prd.ps1` | ✅ |
| Manifestos de todos | `git clone` de cada repo | ✅ |
| Configuração do túnel | `vm/cloudflared-prd.yml` + o `.json` da credencial | ✅ |
| Jenkins (jobs e histórico) | `/var/lib/jenkins` inteiro, por `tar` | ⚠️ ver abaixo |
| Imagens do registro | **não precisa** — a esteira reconstrói | ✅ |

⚠️ **O `TOKEN_ENCRYPTION_KEY` de cada projeto tem que ir.** Ele cifra tokens
OAuth dos streamers (urupix) e credenciais de adquirente (sigma). Com chave
nova, a decifragem falha e o código trata como *"não configurado"*: o serviço
sobe, responde 200, e as credenciais somem **sem uma linha de erro**. Já foi
medido hoje — as impressões SHA-256 dos dois lados precisam bater.

⚠️ **O `NFE_VAULT_KEK` do Veltrixa idem**, para os certificados digitais.

### O Jenkins

`/var/lib/jenkins` guarda jobs, histórico, credenciais cifradas e o `master.key`
que as decifra.

⚠️ Copiar **só** o `config.xml` sem o `secrets/master.key` deixa o Jenkins de pé
com todas as credenciais ilegíveis — e o erro aparece no meio de um build, como
"credencial não encontrada".

    sudo systemctl stop jenkins
    sudo tar czf /tmp/jenkins.tgz -C /var/lib jenkins
    # restaurar do outro lado, com o serviço parado, e conferir o dono:
    sudo chown -R jenkins:jenkins /var/lib/jenkins

---

## Caminho C — máquina nova como NÓ do cluster atual

Adicionar a máquina nova ao MicroK8s como segundo nó, deixar as cargas
migrarem, e depois remover a VM.

⚠️ **Não recomendo hoje**, por um motivo concreto: o armazenamento é
`hostpath` — o disco é **local ao nó**. Um Pod que mude de máquina não leva o
volume junto: ele sobe com o diretório vazio. Para este caminho valer, o
armazenamento precisaria virar rede (Longhorn, NFS) antes — e isso é um projeto
próprio.

---

## A ordem, no caminho recomendado

1. **Instalar Ubuntu LTS** na máquina nova. Rede em **IP fixo** desta vez — a
   dívida de DHCP que já custou três trocas de endereço num dia.
2. **MicroK8s** com os mesmos addons: `hostpath-storage`, `ingress`, `registry`.
3. **Clonar os repositórios** e aplicar os overlays `prd`.
4. **Restaurar os segredos** pelos scripts (as chaves de cifra têm que bater).
5. **Migrar os dados** com o túnel ainda apontando para a VM — sem pressa.
6. **Conferir com `-Conferir`**, que agora compara LINHAS e não tabelas.
7. **A janela**: parar o túnel na VM, rodar a migração uma última vez, subir o
   túnel na máquina nova.
8. **A volta**: religar o túnel na VM. Ela permanece intacta até você mandar
   apagar.

⚠️ **Não desligar a VM no mesmo dia.** Ela é a volta. O corte de hoje só foi
seguro porque a estação continuou íntegra o tempo todo.

---

## O que medir antes de começar

A máquina nova precisa comportar o que a VM usa hoje:

    disco    77 GB usados (e 23 GB disso é imagem reconstruível)
    memória  14 GB em uso de 19 GB
    Pods     59

⚠️ E **a GPU muda o desenho**. Os serviços de IA (Kokoro, Chatterbox, Whisper,
Ollama) não estão na VM porque o VMware não repassa CUDA. Numa máquina nativa
com placa de vídeo, eles passam a caber — e aí o urupix ganha voz sintetizada
de volta em produção, que hoje depende da estação estar ligada.

Isso é argumento a favor do hardware nativo que não tem a ver com desempenho:
é a única forma de a produção ficar **de fato** independente desta estação.

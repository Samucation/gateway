# Migração da infraestrutura para a máquina remota

Decidido em 19/08/2026: uma máquina da rede interna (32 GB) passa a ser o
**host de infraestrutura da casa** — k3s, Jenkins, Kong e o túnel Cloudflare.
Esta estação de trabalho volta a ser estação de trabalho.

Este documento existe porque a migração tem **uma ordem certa**, e a ordem
óbvia é a errada.

---

## O raio de alcance

Hoje, nesta máquina, moram três coisas amarradas:

1. **O túnel Cloudflare** — 20 hostnames públicos entram por ele
2. **O Kong central** (`:8050`) — roteia esses 20 para 6 projetos
3. **As aplicações** — Urupix (`:3100`), sigma-financeiro (`:3200`), OpusChat,
   central-ia, Veltrixa, sigma-midia

Entre os 20 hostnames está **`urupix.com.br`**, que é produto no ar, com
usuário de verdade e dinheiro de verdade passando (doações PIX). Qualquer
janela de indisponibilidade ali é sentida por gente.

## ⚠️ Por que "mudar o Kong primeiro" é a ordem errada

Parece natural: o Kong é o ponto de entrada, então move-se ele e pronto.

Só que as **aplicações continuam aqui**. O caminho de cada requisição viraria:

```
internet → túnel (remota) → Kong (remota) → rede local → aplicação (AQUI)
```

Três problemas de uma vez:

- **um salto a mais** em toda requisição, incluindo as de pagamento;
- **esta máquina continua indispensável** — o objetivo era o contrário;
- **duas máquinas passam a ser ponto único de falha** em vez de uma.

O Kong muda de casa **por último**, quando já houver o que servir do outro lado.

---

## As fases

Cada fase é útil sozinha e reversível. Nenhuma exige a seguinte para valer.

### Fase 1 — a máquina remota ganha vida (RISCO ZERO)

Nada público muda. Nada que está no ar é tocado.

- instalar o k3s
- instalar o Jenkins
- subir a homologação do Veltrixa (o `k8s/` já existe em `system-api`)
- alcançar por `hosts` da rede interna: `loja.veltrixa.hmg` etc.

No fim desta fase existe um ambiente de homologação de verdade, e o Kong daqui
não foi tocado.

### Fase 2 — Jenkins assume a construção das imagens

Hoje quem constrói e publica é o `scripts/publicar-imagens.ps1`, rodado à mão.
O Jenkins passa a fazer isso a cada commit na `main`: constrói, marca com o SHA,
empurra para o `ghcr.io` e aplica no k3s de homologação.

Ganho concreto: **acaba o "funciona na minha máquina"**. A imagem passa a sair
sempre do mesmo lugar, a partir de código commitado.

### Fase 3 — um projeto de verdade migra (o menor primeiro)

Escolher o projeto de **menor risco** e migrá-lo inteiro para a remota, ainda
servido pelo Kong daqui, apontando para a rede local.

Candidato natural: o **sigma-midia**. Já está todo em contêiner, tem duas
aplicações clientes bem definidas e — o mais importante — **não é produto com
usuário final**. Se ele oscilar, quem sente somos nós.

⚠️ O Urupix é o **último**, não o primeiro. É o único com dinheiro de terceiro
passando.

### Fase 4 — Kong e túnel mudam de casa (A JANELA DE RISCO)

Só quando a maioria das aplicações já estiver na remota.

O corte em si é rápido e reversível:

1. subir o Kong na remota, **sem tráfego**, e testar por cabeçalho `Host`
   contra o IP dela — os 20 hostnames, um a um;
2. instalar o `cloudflared` na remota com a **mesma** configuração;
3. o corte: parar o túnel aqui, subir o de lá. O DNS não muda (o CNAME aponta
   para o túnel, e o túnel é o mesmo);
4. conferir os 20 hostnames;
5. **se algo falhar**: parar o túnel de lá, subir o daqui. Volta em menos de um
   minuto.

**Fazer isso na madrugada**, e com o Urupix avisado — é quando ele tem menos
audiência ao vivo.

### Fase 5 — esta máquina é liberada

Desliga o Kong e o túnel daqui. Vira estação de trabalho.

---

## O que precisa ser decidido antes da Fase 4

### O `gerar-kong.mjs` continua valendo?

Hoje o `kong/kong.yml` do gateway é **gerado** a partir do `deploy/kong/kong.yml`
de cada projeto. Isso funciona bem e já evitou perda de configuração.

Se o Kong virar o Ingress do k3s (Kong Ingress Controller), a configuração passa
a ser objeto do cluster (CRD) e **o gerador não serve mais**. Se ele continuar
sendo um contêiner com config declarativa, o gerador continua igual.

Recomendação: **manter o Kong como contêiner declarativo**, do jeito que está.
O gerador é o que impede a configuração de divergir, e ele custou caro para
ficar certo — não vale jogar fora para ganhar elegância.

### O Traefik do k3s some?

Não. Ele continua sendo a entrada **de dentro** do cluster. O Kong fica na
frente, roteando por hostname para o que está no k3s e para o que ainda está em
Docker. São camadas diferentes, e não concorrentes.

---

## Riscos registrados

| Risco | Quando aparece | Como reduzir |
|---|---|---|
| `urupix.com.br` fora do ar | Fase 4 | Corte de madrugada, reversível em 1 min |
| Aplicação que dependia de `localhost` | Fase 3 | Cada projeto tem que ser lido antes de mover |
| Perda de dado de banco | Fase 3 em diante | Backup **antes** de qualquer `docker compose down` |
| A remota vira ponto único de falha | Fase 5 | Aceito conscientemente: hoje esta máquina já é |
| Certificado / `issuer` do Keycloak | Fase 3 | O endereço público muda; token com issuer errado é recusado |

---

## Onde estamos

- [x] Estrutura de k8s do Veltrixa escrita (`system-api/k8s/`)
- [ ] **Fase 1** — k3s e Jenkins na máquina remota ← *próximo*
- [ ] Fase 2 — Jenkins construindo as imagens
- [ ] Fase 3 — sigma-midia migrado
- [ ] Fase 4 — Kong e túnel mudam de casa
- [ ] Fase 5 — esta máquina liberada

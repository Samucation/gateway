# O corte — o roteiro do dia

Leia inteiro antes de começar. São 8 passos e uma volta de menos de um minuto.

**Fazer de madrugada**, quando o Urupix tem menos audiência ao vivo.

---

## Antes de começar

- [ ] os dados **não** foram copiados ainda — isso é o passo 3, e é de propósito
- [ ] a estação continua servindo normalmente
- [ ] `.\vm\migrar-dados.ps1 -Conferir` roda sem erro (só mostra as divergências)

---

## Os passos

### 1. Desligar o watchdog do túnel — ANTES de tudo

```powershell
Disable-ScheduledTask -TaskName NerdQuizTunnelWatchdog
```

⚠️ **Este é o passo 1, não o 2.** O watchdog roda a cada minuto e faz
`Restart-Service NerdQuizTunnel -Force`. Parar o túnel sem desligá-lo antes o
traz de volta em 60 segundos.

E aí acontece o pior caso: **os dois túneis rodando juntos**. Um túnel
Cloudflare aceita várias instâncias e **distribui o tráfego entre elas** — foi
feito assim, para alta disponibilidade. Metade das requisições iria para cada
máquina, e nada daria erro: cada uma funcionaria, só que em ambientes
diferentes. Numa doação PIX, metade dos pagamentos cairia em cada lado.

### 2. Parar o túnel aqui

```powershell
Stop-Service NerdQuizTunnel
```

A partir daqui o tráfego público para. **É esta a janela** — ninguém está
escrevendo em banco nenhum, e é por isso que a cópia do passo 3 sai íntegra.

### 3. Migrar os dados

```powershell
.\vm\migrar-dados.ps1      # os 7 bancos
.\vm\migrar-midia.ps1      # sigma-midia: banco E objetos
```

Os dois **conferem sozinhos** e devolvem código de erro se algo divergir. O
`migrar-midia` faz a conferência que importa de verdade: todo ativo do banco tem
que ter o objeto correspondente no MinIO, e vice-versa.

⚠️ Se qualquer um reprovar, **volte** (passo 8) e investigue com calma. Nenhum
dos dois apaga a origem — a estação continua íntegra.

### 4. Ajustar o ambiente das aplicações no cluster

O cluster foi montado como homologação. Vira produção:

```
SIGMA_AMBIENTE          sandbox -> producao      (sigma-financeiro)
APPLICATION_ENVIRONMENT homologacao -> prd       (veltrixa)
PAYOUTS_LIVE            false -> true            (urupix) ⚠️
```

⚠️ E as credenciais reais: Mercado Pago no urupix, adquirentes no
sigma-financeiro. **Nada disso está no cluster hoje**, de propósito.

### 5. Subir o túnel na VM

```bash
ssh usuario@192.168.15.55 'sudo systemctl start cloudflared'
```

### 6. Conferir os hostnames públicos, um a um

Não confie em "o túnel subiu". Abra os 20 e olhe.

### 7. Vigiar por uns minutos

Log do Kong, log das aplicações, e um pagamento de teste se possível.

### 8. ⚠️ SE FALHAR — a volta

```bash
ssh usuario@192.168.15.55 'sudo systemctl stop cloudflared'
```
```powershell
Start-Service NerdQuizTunnel
Enable-ScheduledTask -TaskName NerdQuizTunnelWatchdog
```

Menos de um minuto, e **a estação nunca foi tocada** — os bancos dela continuam
com tudo. É por isso que a ordem é "parar aqui, migrar, subir lá": a volta não
depende de restaurar nada.

---

## Depois, e só depois

O HMG nesta estação. ⚠️ **Túnel NOVO**, não este reconfigurado — um túnel é um
ID, e o mesmo ID em duas máquinas vira réplica com tráfego dividido. Ver
`../docs/inversao-prd-hmg.md`.

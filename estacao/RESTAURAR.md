# Restaurar o backup desta estação

O backup é feito por [`backup-estacao.ps1`](backup-estacao.ps1) e vive em
`G:\Backups\estacao\<AAAAMMDD-HHMM>\`, **tudo cifrado com `age`**.

> Este documento existe porque backup que nunca foi restaurado não é backup, é
> esperança. O procedimento abaixo foi **executado de ponta a ponta em
> 20/08/2026** — o resultado está no fim.

---

## ⚠️ A chave privada é o único segredo que importa

```
C:\Users\samue\.chaves\hmg-backup-age.key
D:\chaves\hmg-backup-age.key            (segunda cópia, outro disco físico)
```

Sem ela **nenhum** arquivo deste backup abre. Ela é a mesma do backup de
homologação, de propósito: uma segunda chave seria uma segunda coisa para
perder, e o modo de falha aqui não é alguém decifrar o backup — é não haver
mais chave nenhuma no dia de restaurar.

Vale uma terceira cópia fora desta casa.

---

## O que tem em cada carga

| Arquivo | O quê |
|---|---|
| `<contêiner>__<base>.dump.age` | um dump `-Fc` por base (17 deles) |
| `midia.zip.age` | os objetos do MinIO — as imagens que o `sigma_midia` só **indexa** |
| `segredos.zip.age` | os `.env` de todos os projetos |
| `MANIFESTO.txt` | em claro, de propósito: dá para ver o que tem sem a chave |

⚠️ **A mídia e o banco andam juntos.** Restaurar só o banco devolve linhas
apontando para objetos que não existem, e cada imagem do catálogo vira 404.

---

## Restaurar um banco

```powershell
$CARGA = 'G:\Backups\estacao\20260820-1641'
$CHAVE = 'C:\Users\samue\.chaves\hmg-backup-age.key'

# 1. decifrar
age -d -i $CHAVE -o "$env:TEMP\r.dump" "$CARGA\liveflow-db__liveflow.dump.age"

# 2. restaurar num banco NOVO — nunca por cima do vivo, ver o aviso abaixo
docker exec liveflow-db psql -U liveflow -d postgres -c 'CREATE DATABASE restaurado'
docker cp "$env:TEMP\r.dump" liveflow-db:/tmp/r.dump
docker exec liveflow-db pg_restore -U liveflow -d restaurado --no-owner --no-acl /tmp/r.dump

# 3. conferir ANTES de trocar
docker exec liveflow-db psql -U liveflow -d restaurado -c 'select count(*) from "Donation"'
```

⚠️ **Sempre num banco novo primeiro.** `pg_restore` direto por cima do banco
vivo, se o dump estiver ruim, destrói o bom e deixa o ruim — e você descobre
depois de já não ter para onde voltar.

---

## Restaurar a mídia

```powershell
age -d -i $CHAVE -o "$env:TEMP\m.zip" "$CARGA\midia.zip.age"
Expand-Archive "$env:TEMP\m.zip" "$env:TEMP\m" -Force
docker cp "$env:TEMP\m\data\." sigma-midia-minio:/data
docker restart sigma-midia-minio
```

---

## 🐞 Duas armadilhas que custaram tempo ao montar isto

**1. O Git Bash traduz caminho, e o `docker exec` recebe o traduzido.**
`docker exec ... pg_restore /tmp/p.dump` falhou com
`could not open input file "C:/Users/samue/AppData/Local/Temp/p.dump"` — o
MSYS converteu `/tmp/` para um caminho do Windows *a caminho do contêiner
Linux*. Resolve com `export MSYS_NO_PATHCONV=1`.

⚠️ Mas aí o inverso quebra: com a conversão desligada, `age` (que é binário
**Windows**) deixa de entender `/g/Backups/...`. Numa mesma sessão, ou se
alterna, ou — melhor — **usa PowerShell para o `age` e Bash para o Docker**.

**2. PowerShell 5.1 sem BOM lê UTF-8 como ANSI.** O script foi salvo sem BOM e
o interpretador reclamou de uma chave desbalanceada 15 linhas adiante da causa
real. O acento de `ESTAÇÃO` virava `ESTAÃ‡ÃƒO` e quebrava a paridade das aspas.
**Todo `.ps1` deste repositório tem que ter BOM** — o editor grava sem, então
confira depois de editar:

```powershell
$b = [IO.File]::ReadAllBytes($f)
$b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF   # tem que ser True
```

---

## A prova — 20/08/2026

Carga `20260820-1641`, decifrada e restaurada num banco separado, com o vivo
intocado:

```
Donation                50 →     50   ok
PaymentLedgerEntry      23 →     23   ok
PenasLedger             16 →     16   ok
Withdrawal               1 →      1   ok
AgentCommand         12611 →  12611   ok
... 13 tabelas de dinheiro, 0 divergências

sum(Donation.amountCents)   vivo=18800   restaurado=18800   ok
```

Mídia: `midia.zip.age` decifra e traz **247 objetos** reais sob
`data/sigma-midia/`, além de 27 arquivos de metadado do MinIO.

O banco de prova foi removido; o vivo seguiu com as mesmas 50 doações.

---

## A rotação NÃO apaga quando o backup falha

Se qualquer item falhar, o script sai com código 1 e **pula a rotação**. É
regra que nasceu de um defeito real: em `G:\Backups\hmg\veltrixa` havia a pasta
`20260820-1300` com **zero arquivos** — a puxada rodou enquanto a VM caía,
criou a pasta datada e não pôs nada dentro. Numa listagem aquilo tem cara de
backup, e a rotação por dias acabaria trocando as cópias boas por pastas
vazias. Um backup que falhou tem que gritar, não empurrar o bom para fora.

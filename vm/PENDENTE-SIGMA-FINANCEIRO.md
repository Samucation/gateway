# 🔴 O `sigma-financeiro` não pode ser reconstruído — precisa da sua autorização

> Este documento está no `gateway` e **não** no `sigma-financeiro` de propósito.
> A regra de ouro é que aquele repositório eu só consulto; a única exceção que
> você liberou foi a pasta `k8s/`. O conserto abaixo é de **uma linha** e está
> escrito aqui, pronto, esperando você mandar aplicar.

## O que está acontecendo

A esteira do `sigma-financeiro` **nunca passou**. Dez execuções, todas
vermelhas:

    #1   2026-08-20 21:49  FAILURE
    #2   2026-08-21 03:54  FAILURE
    ...
    #10  2026-08-22 14:07  FAILURE

Sempre no mesmo ponto:

    Error: Module not found: Can't resolve '@/generated/prisma/client'
    ERROR: process "/bin/sh -c npm run build" did not complete successfully

## Por que

Três fatos que só fazem estrago juntos:

1. O `prisma/schema.prisma` gera o cliente num caminho próprio:
   `output = "../src/generated/prisma"`.
2. `src/generated/` está no `.gitignore` — então **não vai para o repositório**,
   e portanto **não entra no contexto do build**.
3. O `Dockerfile` faz `npm ci` e depois `npm run build` (`next build`), e
   **nunca roda `prisma generate`**. Não há `postinstall` no `package.json` que
   o faça.

⚠️ **Por isso funciona na sua máquina.** Ali a pasta `src/generated/prisma`
existe, porque em algum momento alguém rodou `prisma generate`. O build local
acha o módulo; o build da esteira, que parte de um clone limpo, não.

É o caso clássico de "compila aqui e não compila lá", e ele só aparece em
ambiente limpo.

## O conserto

Uma linha no `Dockerfile`, antes do `npm run build`:

```dockerfile
RUN npx prisma generate
RUN npm run build
```

Ou, equivalente e talvez melhor, um `postinstall` no `package.json` — assim
qualquer `npm ci`, em qualquer lugar, já deixa o cliente pronto:

```json
"scripts": {
  "postinstall": "prisma generate"
}
```

Prefiro o `postinstall`: ele conserta o build da esteira **e** o de qualquer
máquina nova, sem depender de ninguém lembrar do passo manual.

## ⚠️ Por que isso é urgente, e não cosmético

A imagem que está rodando em produção hoje —
`localhost:32000/sigma-financeiro:20260820-0636` — **não pode ser baixada do
registro** e **não pode ser reconstruída**.

Tentei reproduzi-la a partir do commit `67f16bb`, que é o último anterior ao
horário da etiqueta. Falhou pelo mesmo motivo: o `prisma generate` nunca esteve
no `Dockerfile`.

Ou seja: o serviço que move dinheiro está rodando de uma camada descompactada
no disco da VM. Enquanto o Pod não for reagendado, tudo bem. Se ele for —
despejo por disco cheio (**já aconteceu aqui**), reinício de nó, um
`delete pod` — a imagem não volta, e não há de onde tirar outra.

Dos treze serviços, este é o único que continua nessa situação. Os outros doze
foram reconstruídos e republicados em 22/08/2026.

## O que fazer quando você autorizar

1. Aplicar o `postinstall` (ou o `RUN npx prisma generate`).
2. Deixar a esteira rodar. Ela agora **confere** que a imagem publicada pode
   ser baixada — se o push não prestar, ela falha ali mesmo.
3. Promover para produção pelo botão.
4. Rodar `gateway/vm/conferir-deriva-de-tag.ps1` para confirmar que o overlay
   de `prd` ficou apontando para a tag nova.

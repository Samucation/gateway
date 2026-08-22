# Registros de DNS que sobraram e precisam sair (só você pode)

São registros na sua conta da Cloudflare. Eu removi as rotas do túnel; o que
resta é apagar o CNAME, e isso é no painel.

## `central-ia-sandbox.cursodetecnologia.dev.br`

**Substituído por `central-ia-hmg.cursodetecnologia.dev.br`**, que está no ar
(200) e serve a homologação do central-ia na estação.

O sandbox apontava para `192.168.15.9:8030` — a porta do Kong que o central-ia
tinha só para ele. Esse Kong foi aposentado na consolidação de 14/08/2026, e a
rota ficou apontando para o vazio desde então.

Rota retirada do túnel em 22/08/2026 (`/etc/cloudflared/config.yml` e
`vm/cloudflared-prd.yml`). Cópia de segurança do arquivo antigo na VM em
`/etc/cloudflared/config.yml.antes-de-tirar-sandbox`.

⚠️ Enquanto o CNAME existir apontando para o túnel, quem abrir o endereço vai
receber erro da Cloudflare em vez de "domínio não existe". Não quebra nada —
só é um endereço morto que aparece em qualquer varredura e faz perder tempo.

## Os dois que já estavam anotados

    urupix.com.br.cursodetecnologia.dev.br
    www.urupix.com.br.cursodetecnologia.dev.br

Nasceram de um erro de digitação ao criar o registro do urupix: o domínio
completo foi colado num campo que já acrescenta a zona, gerando o nome duplicado.
Nunca serviram nada.

---

## Como conferir depois de apagar

    curl -s -o /dev/null -w "%{http_code}\n" https://central-ia-sandbox.cursodetecnologia.dev.br

Com o CNAME apagado, o `curl` falha na RESOLUÇÃO (erro 6, "could not resolve
host") em vez de devolver código HTTP. É essa a diferença entre "não existe" e
"existe e está quebrado".

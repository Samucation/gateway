# Melhoria — lista de aplicações confiáveis, com tela para gerenciar

**Estado:** anotado, não construído.
**Data:** 2026-08-16.
**Quem pediu:** Samuel.
**De onde veio:** ao integrar outro aplicativo ao OpusChat, apareceu que o
rate-limit da API de mensageria é `limit_by: ip`. Dois clientes saindo pelo
mesmo IP — o que acontece com todos os contêineres desta máquina — dividem o
mesmo balde. Um vizinho barulhento estrangula o outro, e o sintoma (429
aleatório) não aponta para a causa.

## O que ele quer

O limite por IP **continua** para quem vem de fora. As aplicações do próprio
ecossistema, registradas, passam por cima dele — para que nenhuma derrube a
outra. E a lista de quem é confiável tem que ser gerenciável por uma **tela**,
não por edição de arquivo.

O console já existe (`console/ui`, Angular, servido pelo `console/servidor.mjs`),
então é onde essa tela nasce.

## ⚠️ A parte do desenho que precisa mudar antes de construir

A frase que motivou o pedido foi: *"mesmo que a gente seja invadido no servidor
ninguém tome posse"*.

**Uma whitelist por IP não entrega isso.** Se o atacante está dentro do
servidor, ele **é** o IP confiável — passa por cima do limite exatamente como
as aplicações legítimas, e ainda ganha um caminho sem freio. A lista por IP
protege contra o vizinho barulhento, não contra invasão.

O que entrega a intenção é identificar a **aplicação**, não a origem:

| Critério | Contra vizinho barulhento | Contra invasor dentro do servidor |
|---|---|---|
| IP na whitelist | ✅ | ❌ — o invasor herda o IP |
| **Credencial registrada** | ✅ | ✅ — precisa roubar a chave também |

Ou seja: a lista deve ser de **credenciais** (a API key, ou um consumer do
Kong), com o IP como condição **adicional** — "esta chave, vinda desta faixa".
As duas juntas, e não uma no lugar da outra.

Detalhe que fecha o argumento: se o invasor já tem a chave de um cliente, o
limite é o menor dos problemas — ele fala pela aplicação. O limite existe para
proteger a **disponibilidade** entre vizinhos; a posse é problema de
credencial, e é lá que se resolve.

## Desenho sugerido

1. **`limit_by: header` no `Authorization`** nas rotas da API de mensageria —
   é o que a rota da mesa do atendente já faz, e resolve sozinho 90% do
   problema: cada credencial ganha o próprio balde, e um cliente não derruba o
   outro nem estando no mesmo IP.
2. **Consumers do Kong** para as aplicações do ecossistema, com teto próprio
   (ou sem teto) — é o mecanismo nativo, e o que a tela vai gerenciar.
3. **Tela no console**: listar, acrescentar e remover, mostrando **quem** é a
   aplicação, **quando** entrou e **quem** colocou. Lista de exceção sem autor
   e sem data vira porta que ninguém sabe explicar.
4. **Guarda de teste** que falhe se alguma rota da API voltar para
   `limit_by: ip` sozinho.

## O que NÃO fazer

* whitelist de IP **sozinha** — ver acima;
* faixa larga (`172.16.0.0/12` inteira) como exceção: é toda a rede Docker,
  incluindo qualquer contêiner que alguém suba amanhã;
* exceção sem prazo nem revisão — a mesma armadilha do marcador permanente da
  §16 do OpusChat: exceção que ninguém revisa vira exceção esquecida.

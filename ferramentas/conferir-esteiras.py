#!/usr/bin/env python3
"""Guarda das esteiras: procura, em TODOS os repositorios, defeitos que ficam
verdes.

    python ferramentas/conferir-esteiras.py

Sai com codigo 1 se achar qualquer coisa. Feito para rodar antes de confiar num
build, e barato o bastante para rodar sempre.

---------------------------------------------------------------------------
POR QUE ESTE ARQUIVO EXISTE
---------------------------------------------------------------------------
Os dois defeitos conferidos aqui tem a mesma assinatura, e e por isso que eles
merecem uma guarda em vez de uma anotacao: **os dois deixam a esteira VERDE**.
Nenhum dos dois aparece num log de build. Os dois so aparecem depois, em outra
maquina, como se fosse outro problema.

1. ATESTADOS DO BUILDKIT (`--provenance=false --sbom=false`)

   Sem essas duas opcoes o BuildKit publica um INDICE OCI com dois filhos: a
   imagem `linux/amd64` e um atestado `unknown/unknown`. O `docker push` envia o
   indice, sai com codigo 0, e a tag aparece certinha em
   `/v2/<nome>/tags/list`. O manifesto filho NAO vai junto.

   Quem ja tem a imagem no cache local do containerd continua subindo. Quem
   precisa BAIXAR toma:

       failed to pull and unpack image: httpReadSeeker: failed open:
       content at .../manifests/sha256:... not found

   Em 22/08/2026 isso derrubou a implantacao de homologacao do `sigma-midia` e
   do `sigma-financeiro` com imagens de tres dias antes. A esteira estava verde,
   producao rodava -- so porque a VM ainda tinha as camadas em cache. Um
   `docker system prune` na VM teria derrubado producao sem nada ter mudado.

2. GUARDA DE CONTEXTO NOS ESTAGIOS DE HOMOLOGACAO

   Um estagio que aplica manifesto de homologacao sem conferir em QUE cluster
   esta falando aplica em qualquer um que o `kubectl` tenha configurado. Ja
   aconteceu duas vezes: a esteira reverteu PRODUCAO para a versao de
   homologacao, e o build terminou em SUCCESS nas duas.

---------------------------------------------------------------------------
⚠️ E A LICAO MAIOR
---------------------------------------------------------------------------
Todo Jenkinsfile ESCRITO A MAO ja perdeu pelo menos uma correcao sistematica
que os gerados receberam. O `system-api` perdeu as duas acima. Enquanto houver
arquivo a mao, esta guarda e o unico jeito de a correcao alcançar todo mundo.
"""
import re
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]

# `docker build ` com espaco: evita casar com `docker builder prune`.
BUILD = re.compile(r"docker\s+build\s")
ATESTADO = re.compile(r"--provenance=false")

# Estagio que mexe em cluster de homologacao.
APLICA_HMG = re.compile(r"overlays[/\\]hmg")
GUARDA_HMG = re.compile(r"HMG_CONTEXTO|KUBECTL_HMG")


def conferir(arquivo: Path):
    """Devolve a lista de problemas de um Jenkinsfile."""
    problemas = []
    try:
        texto = arquivo.read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        return [f"nao consegui ler: {e}"]

    linhas = texto.splitlines()

    for n, linha in enumerate(linhas, 1):
        # Comentario nao constroi nada.
        cru = linha.strip()
        if cru.startswith("//") or cru.startswith("*") or cru.startswith("#"):
            continue
        if BUILD.search(linha) and not ATESTADO.search(linha):
            problemas.append(
                f"linha {n}: `docker build` sem `--provenance=false --sbom=false`"
            )

    # A guarda de contexto e conferida no arquivo INTEIRO, e nao por linha: ela
    # costuma morar num `environment` ou num `when`, longe do `apply`.
    if APLICA_HMG.search(texto) and not GUARDA_HMG.search(texto):
        problemas.append(
            "aplica `overlays/hmg` sem guarda de contexto (HMG_CONTEXTO/KUBECTL_HMG)"
        )

    return problemas


def main():
    arquivos = sorted(RAIZ.glob("*/Jenkinsfile"))
    if not arquivos:
        print(f"nenhum Jenkinsfile encontrado em {RAIZ}")
        return 1

    total = 0
    for arquivo in arquivos:
        problemas = conferir(arquivo)
        repo = arquivo.parent.name
        if problemas:
            total += len(problemas)
            print(f"\n  {repo}")
            for p in problemas:
                print(f"    FALHA: {p}")
        else:
            print(f"  {repo}: ok")

    print()
    if total:
        print(f"{total} problema(s). Estes defeitos NAO aparecem no log do build.")
        return 1

    print(f"{len(arquivos)} esteiras conferidas, nenhum problema.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# ===========================================================================
# Prova, objeto por objeto, se uma migracao do NF-e JA foi aplicada no banco.
#
#     python3 conferir-migracoes-nfe.py            # so confere
#     python3 conferir-migracoes-nfe.py --aplicar  # registra as que passaram
#
# ---------------------------------------------------------------------------
# 🐞 POR QUE NAO DA PARA FAZER ISTO COM `grep`
# ---------------------------------------------------------------------------
# A primeira versao desta conferencia era um `grep -oiE 'ALTER TABLE ... ADD
# COLUMN ...'` -- os dois na MESMA linha. Nestes arquivos eles estao em linhas
# diferentes:
#
#     ALTER TABLE nfe.tenant_fiscal_profile
#         ADD COLUMN clas_estab_ind VARCHAR(2);
#
# Resultado: a busca nao achava nada, a lista de objetos a conferir saia VAZIA,
# e o script anunciava "ok, tudo que ela cria ja esta no banco" para cinco
# migracoes sobre as quais nao tinha conferido UMA COISA.
#
# ⚠️ Conferencia que nao encontra nada para conferir PASSA. E o pior tipo de
# verde: some com o alarme e ainda produz uma linha dizendo que esta tudo bem.
# Aqui, migracao da qual nao se extraiu NENHUM objeto e tratada como REPROVADA.
#
# Num sistema fiscal isso nao e detalhe: marcar como aplicada uma migracao que
# nao rodou deixa o banco sem uma coluna que a emissao usa, e o erro aparece na
# hora de emitir a nota.
# ===========================================================================
import re
import subprocess
import sys
import zlib
from pathlib import Path

DIR = Path("/mnt/e/Desenvolvimento/Dev/Workspace/system-api/nfe-service"
           "/src/main/resources/db/migration")
NS, POD, BANCO, USUARIO = "veltrixa", "veltrixa-nfe-postgres-0", "nfe_db", "nfe"


def sql(consulta: str) -> str:
    r = subprocess.run(
        ["kubectl", "exec", "-n", NS, POD, "--",
         "psql", "-U", USUARIO, "-d", BANCO, "-tAc", consulta],
        capture_output=True, text=True)
    return r.stdout.strip()


def objetos(texto: str):
    """Tabelas criadas, colunas acrescentadas e tipos alterados."""
    achados = []

    for m in re.finditer(r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:nfe\.)?(\w+)",
                         texto, re.I):
        achados.append(("tabela", m.group(1).lower(), None, None))

    # `ALTER TABLE x` e `ADD COLUMN y` costumam estar em linhas diferentes:
    # varre o arquivo guardando qual e a tabela corrente.
    tabela = None
    for linha in texto.splitlines():
        m = re.search(r"ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:nfe\.)?(\w+)", linha, re.I)
        if m:
            tabela = m.group(1).lower()
        for c in re.finditer(r"ADD\s+COLUMN\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)", linha, re.I):
            if tabela:
                achados.append(("coluna", tabela, c.group(1).lower(), None))
        for c in re.finditer(r"ALTER\s+COLUMN\s+(\w+)\s+TYPE\s+([A-Za-z]+)", linha, re.I):
            if tabela:
                achados.append(("tipo", tabela, c.group(1).lower(), c.group(2).lower()))
    return achados


def existe(tipo, tabela, coluna, esperado):
    if tipo == "tabela":
        return sql(f"SELECT count(*) FROM information_schema.tables "
                   f"WHERE table_schema='nfe' AND table_name='{tabela}'") == "1"
    if tipo == "coluna":
        return sql(f"SELECT count(*) FROM information_schema.columns "
                   f"WHERE table_schema='nfe' AND table_name='{tabela}' "
                   f"AND column_name='{coluna}'") == "1"
    if tipo == "tipo":
        # `VARCHAR` chega como `character varying` no catalogo.
        atual = sql(f"SELECT data_type FROM information_schema.columns "
                    f"WHERE table_schema='nfe' AND table_name='{tabela}' "
                    f"AND column_name='{coluna}'")
        alvo = "character varying" if esperado.startswith("varchar") else esperado
        return atual == alvo
    return False


def soma(caminho: Path) -> int:
    """Mesmo calculo do Flyway: CRC32 linha a linha, sem o terminador."""
    crc = 0
    with caminho.open("rb") as arq:
        for linha in arq:
            crc = zlib.crc32(linha.rstrip(b"\r\n"), crc)
    return crc - (1 << 32) if crc >= (1 << 31) else crc


def main():
    aplicar = "--aplicar" in sys.argv
    arquivos = sorted(DIR.glob("V*.sql"),
                      key=lambda p: int(re.match(r"V(\d+)__", p.name).group(1)))

    pendentes = []
    for f in arquivos:
        v = re.match(r"V(\d+)__", f.name).group(1)
        if sql(f"SELECT count(*) FROM nfe.flyway_schema_history WHERE version='{v}'") == "0":
            pendentes.append((v, f))

    if not pendentes:
        print("  nada pendente no historico")
        return 0

    print(f"== {len(pendentes)} migracao(oes) sem registro: "
          f"{', '.join('V' + v for v, _ in pendentes)}")
    print()
    print("== provando que os objetos de cada uma ja estao no banco ==")

    aprovadas, reprovadas = [], []
    for v, f in pendentes:
        alvos = objetos(f.read_text(encoding="utf-8", errors="replace"))
        if not alvos:
            # ⚠️ Nao encontrar o que conferir NAO e aprovacao.
            print(f"  V{v:<4} ❌ nao extrai nenhum objeto deste arquivo — "
                  f"confira a mao antes de registrar")
            reprovadas.append(v)
            continue

        faltando = [a for a in alvos if not existe(*a)]
        if faltando:
            partes = []
            for t, tab, col, _ in faltando:
                partes.append(f"{t}:{tab}.{col}" if col else f"{t}:{tab}")
            print(f"  V{v:<4} ❌ NAO rodou — falta: {', '.join(partes)}")
            reprovadas.append(v)
        else:
            print(f"  V{v:<4} ok — {len(alvos)} objeto(s) conferido(s)")
            aprovadas.append((v, f))

    if reprovadas:
        print()
        print("  ❌ ha migracao que de fato nao rodou (ou que nao consegui ler).")
        print("     Nao registro NADA: marcar migracao nao aplicada esconde um")
        print("     banco incompleto, e num sistema fiscal isso vira nota errada.")
        return 1

    if not aplicar:
        print()
        print(f"  (ensaio) rode com --aplicar para registrar as {len(aprovadas)}")
        return 0

    print()
    print("== registrando ==")
    for v, f in aprovadas:
        desc = re.sub(r"^V\d+__|\.sql$", "", f.name).replace("_", " ")
        c = soma(f)
        sql(f"""INSERT INTO nfe.flyway_schema_history
                  (installed_rank, version, description, type, script, checksum,
                   installed_by, installed_on, execution_time, success)
                SELECT COALESCE(MAX(installed_rank), 0) + 1, '{v}', '{desc}', 'SQL',
                       '{f.name}', {c}, 'conserto-pos-migracao', now(), 0, true
                FROM nfe.flyway_schema_history""")
        print(f"  V{v:<4} registrada (checksum {c})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

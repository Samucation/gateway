#!/usr/bin/env python3
# ===========================================================================
# Mede a DURAÇÃO real de um mp3 somando os quadros — sem ffmpeg.
#
#     python3 medir-duracao-mp3.py <arquivo.mp3>
#
# ⚠️ Tamanho em bytes é proxy ruim quando o bitrate é variável, e "o áudio
# existe" não responde a pergunta que interessa: ele contém a frase INTEIRA?
#
# Aqui a duração sai de somar os quadros de verdade, e o script também diz se o
# arquivo tem cabeçalho de duração (Xing/Info). A ausência dele importa: sem
# duração declarada, alguns tocadores param antes do fim, e o sintoma é
# exatamente "a última palavra sumiu".
# ===========================================================================
import sys

# (versão, camada) -> tabela de bitrate; só o que o Kokoro usa (MPEG-1 layer 3)
BITRATES_V1_L3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
BITRATES_V2_L3 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]
TAXAS_V1 = [44100, 48000, 32000, 0]
TAXAS_V2 = [22050, 24000, 16000, 0]


def medir(caminho):
    dados = open(caminho, "rb").read()
    i = 0
    # Pula ID3v2, se houver.
    if dados[:3] == b"ID3":
        tam = (dados[6] << 21) | (dados[7] << 14) | (dados[8] << 7) | dados[9]
        i = 10 + tam

    duracao = 0.0
    quadros = 0
    tem_cabecalho_duracao = b"Xing" in dados[:4096] or b"Info" in dados[:4096]

    while i + 4 <= len(dados):
        if dados[i] != 0xFF or (dados[i + 1] & 0xE0) != 0xE0:
            i += 1
            continue
        versao = (dados[i + 1] >> 3) & 0x03      # 3 = MPEG-1, 2 = MPEG-2
        camada = (dados[i + 1] >> 1) & 0x03      # 1 = layer III
        idx_bit = (dados[i + 2] >> 4) & 0x0F
        idx_taxa = (dados[i + 2] >> 2) & 0x03
        padding = (dados[i + 2] >> 1) & 0x01
        if camada != 1 or idx_bit in (0, 15) or idx_taxa == 3:
            i += 1
            continue

        if versao == 3:
            bitrate = BITRATES_V1_L3[idx_bit] * 1000
            taxa = TAXAS_V1[idx_taxa]
            amostras = 1152
        else:
            bitrate = BITRATES_V2_L3[idx_bit] * 1000
            taxa = TAXAS_V2[idx_taxa]
            amostras = 576
        if not bitrate or not taxa:
            i += 1
            continue

        tamanho_quadro = int(amostras / 8 * bitrate / taxa) + padding
        if tamanho_quadro <= 4:
            i += 1
            continue
        duracao += amostras / taxa
        quadros += 1
        i += tamanho_quadro

    return duracao, quadros, tem_cabecalho_duracao, len(dados)


if __name__ == "__main__":
    for arq in sys.argv[1:]:
        try:
            d, q, cab, tam = medir(arq)
            print(
                f"  {arq.split('/')[-1][:20]:22} {d:6.2f}s  {q:5d} quadros  "
                f"{tam:7d} bytes  duracao declarada: {'sim' if cab else 'NAO'}"
            )
        except Exception as e:  # arquivo ilegível é resposta também
            print(f"  {arq}: nao consegui ler ({e})")

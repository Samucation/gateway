#!/usr/bin/env bash
# O mp3 que o app serve contém a frase INTEIRA?
#
# Gera a frase exata do teste do admin, mede a DURAÇÃO real (somando quadros) e
# compara com a mesma frase sem a última palavra. Se as duas durarem o mesmo, a
# última palavra não está no áudio.
#
# ⚠️ Também informa se o mp3 declara duração (cabeçalho Xing/Info). Sem ela,
# alguns tocadores param antes do fim — e o sintoma é a última palavra sumindo,
# com o arquivo perfeitamente completo no disco.
set -uo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOTOR=${MOTOR:-http://kokoro.estacao.svc.cluster.local:8880}
VOZ=${VOZ:-pf_dora}
TMP=/tmp/vozes-medidas
mkdir -p "$TMP"; rm -f "$TMP"/*.mp3

gerar() { # <apelido> <texto>
  kubectl run gvz$RANDOM -n central-ia --rm -i --restart=Never \
    --image=curlimages/curl:8.10.1 --quiet -- \
    -s --max-time 120 -X POST "$MOTOR/v1/audio/speech" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"kokoro\",\"voice\":\"$VOZ\",\"input\":\"$2\",\"response_format\":\"mp3\",\"lang_code\":\"p\"}" \
    2>/dev/null > "$TMP/$1.mp3"
}

echo "== gerando =="
gerar completa "Obrigado pela sua doacao!"
gerar sem_final "Obrigado pela sua"
gerar com_acento "Obrigado pela sua doação!"
gerar com_sobra "Obrigado pela sua doacao! Ate a proxima."

echo
echo "== duracao real de cada uma =="
python3 "$AQUI/medir-duracao-mp3.py" "$TMP"/completa.mp3 "$TMP"/sem_final.mp3 "$TMP"/com_acento.mp3 "$TMP"/com_sobra.mp3

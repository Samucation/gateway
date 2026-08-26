#!/usr/bin/env python3
"""Faz o tunel entrar no gateway por IPv4 EXPLICITO, e nao por `localhost`.

    python gateway/estacao/tunel-ipv4-explicito.py            # mostra o que faria
    python gateway/estacao/tunel-ipv4-explicito.py --aplicar   # grava

---------------------------------------------------------------------------
O problema
---------------------------------------------------------------------------
O `cloudflared` chama `http://localhost:8050`. `localhost` resolve **IPv6
antes de IPv4**, e quando um contêiner Docker aposentado prende `[::]:8050` o
túnel inteiro passa a falar com ele -- com a configuração de meses atrás, que
não conhece os domínios novos.

Medido em 25/08/2026, com o `gateway-kong` do Docker de volta no ar:

    dominio                          publico   IPv4 (k3s)   IPv6 (intruso)
    cartorioconceicaoaraguaia...     404       200          404
    cartorio-auth...                 404       302          404
    opuschat...                      503       200          503
    central-ia...                    503       200          503
    sigma-midia...                   503       200          503
    cafe-api...                      503       200          503

⚠️ A resposta pública é SEMPRE igual à do IPv6. Isso não é indício, é prova:
todo o tráfego externo estava indo para o intruso, com o cluster saudável do
lado. Seis domínios fora do ar com `kubectl get pods` todo verde.

---------------------------------------------------------------------------
Por que isto, e não `docker rm -f gateway-kong`
---------------------------------------------------------------------------
Remover o contêiner é o conserto de raiz, e é o que a regra de ouro manda. Mas
hoje ele tem um refém: `sigma-financeiro` está em CrashLoopBackOff no k3s (sem
endpoints, 502) e só responde 200 porque o Kong aposentado o encaminha para
`host.docker.internal:3200`. Removê-lo consertaria seis domínios e derrubaria
um serviço de PAGAMENTO.

Então este script troca `localhost` por `127.0.0.1` em todos os hostnames
MENOS os do `sigma-financeiro`, que continuam saindo pelo caminho que hoje
funciona para eles. Nenhum domínio piora; seis melhoram.

⚠️ Isto é contorno, não cura. Enquanto o contêiner existir, ele volta a cada
partida do Docker e rouba a porta de novo. O conserto de verdade é arrumar o
`sigma-financeiro` no k3s e então remover o contêiner de vez.
"""
import io
import os
import re
import shutil
import sys

CONFIG = os.path.join(os.path.expanduser('~'), '.cloudflared', 'config.yml')

# Os hostnames que continuam em `localhost`, de propósito.
#
# ⚠️ Vazio desde 25/08/2026, 23h. Estava aqui o `sigma-financeiro`: naquele
# momento ele era um REFÉM -- CrashLoopBackOff no k3s (sem endpoints, 502) e
# respondendo 200 só porque o Kong aposentado o encaminhava para
# `host.docker.internal:3200`. Mandá-lo para o IPv4 derrubaria um serviço de
# pagamento para consertar os outros.
#
# Ele se recuperou sozinho assim que a carga do nó baixou (a distro tinha
# acabado de reiniciar e tudo subia ao mesmo tempo). Medido depois: endpoint
# ativo em 10.42.0.130:3200 e **200 pelos dois caminhos**. Sem refém, a lista
# fica vazia -- e o contêiner aposentado pode enfim ser removido.
#
# A lista continua existindo porque a situação se repete: se um dia um serviço
# só responder pelo caminho antigo, ele entra aqui em vez de a correção inteira
# ser adiada.
REFENS = ()

ALVO = 'http://localhost:8050'
NOVO = 'http://127.0.0.1:8050'


def main():
    aplicar = '--aplicar' in sys.argv

    with io.open(CONFIG, encoding='utf-8', newline='') as f:
        bruto = f.read()

    # `newline=''` preserva CRLF exatamente como está. Reescrever o arquivo com
    # a quebra de linha trocada faria o diff inteiro parecer alteração.
    quebra = '\r\n' if '\r\n' in bruto else '\n'
    linhas = bruto.split(quebra)

    hostname_atual = None
    mudadas, poupadas = [], []

    for i, linha in enumerate(linhas):
        m = re.match(r'\s*-?\s*hostname:\s*(\S+)', linha)
        if m:
            hostname_atual = m.group(1)
            continue

        if ALVO not in linha:
            continue

        if hostname_atual and any(r in hostname_atual for r in REFENS):
            poupadas.append((i + 1, hostname_atual))
            continue

        linhas[i] = linha.replace(ALVO, NOVO)
        mudadas.append((i + 1, hostname_atual or '(sem hostname acima)'))

    print('=== passariam a usar IPv4 explicito: %d ===' % len(mudadas))
    for n, h in mudadas:
        print('  linha %-5d %s' % (n, h))

    print()
    print('=== poupadas de proposito: %d ===' % len(poupadas))
    for n, h in poupadas:
        print('  linha %-5d %s   (so responde pelo caminho antigo)' % (n, h))

    if not aplicar:
        print()
        print('Nada gravado. Rode com --aplicar para valer.')
        return 0

    reserva = CONFIG + '.antes-do-ipv4'
    shutil.copy2(CONFIG, reserva)
    with io.open(CONFIG, 'w', encoding='utf-8', newline='') as f:
        f.write(quebra.join(linhas))

    print()
    print('gravado. copia do anterior em: %s' % reserva)
    print('agora e preciso RECARREGAR o cloudflared -- o arquivo sozinho nao vale.')
    return 0


if __name__ == '__main__':
    sys.exit(main())

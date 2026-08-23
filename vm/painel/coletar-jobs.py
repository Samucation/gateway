#!/usr/bin/env python3
# ===========================================================================
# A SAUDE DAS TAREFAS AGENDADAS — o que o painel nao tinha como ver
# ===========================================================================
# O painel fala com o Jenkins, e o Jenkins nao sabe nada dos CronJobs do
# Kubernetes. E sao eles que fazem o trabalho que ninguem olha: backup de nove
# bancos, disparo de aviso de live, fila de entrega de notificacao, vigia de
# live, sincronizacao noturna.
#
# ⚠️ TAREFA AGENDADA QUEBRA EM SILENCIO. Ninguem esta olhando as 5h da manha,
# e o estrago so aparece no dia em que o backup precisa existir. Ja aconteceu:
# o backup diario apontava para um arquivo inexistente, falhava com `0x1`, e o
# agendador seguia mostrando "Pronto".
#
# Este coletor roda NA VM, escreve um JSON no `userContent` e o painel o le.
# Escolha deliberada: o painel e uma pagina no navegador, sem acesso ao
# cluster, e dar esse acesso a ele significaria expor credencial de cluster no
# navegador de quem abrisse a tela.
#
# ---------------------------------------------------------------------------
# COMO ELE DECIDE QUE ALGO ESTA RUIM
# ---------------------------------------------------------------------------
# Duas perguntas diferentes, e confundi-las esconde metade dos defeitos:
#
#   1. ELE DISPAROU?          `lastScheduleTime` velho = o controlador parou.
#   2. DISPAROU E DEU CERTO?  `lastSuccessfulTime` muito atras do disparo =
#                             ele roda e falha, que e pior: parece vivo.
#
# 🐞 Um painel que so olhasse a primeira daria tudo verde para uma tarefa que
# dispara de minuto em minuto e falha em todas.
import json
import re
import subprocess
import sys
from datetime import datetime, timezone

DESTINO = "/var/lib/jenkins/userContent/painel/jobs.json"
KUBECTL = ["microk8s", "kubectl"]


def agora():
    return datetime.now(timezone.utc)


def instante(txt):
    if not txt:
        return None
    return datetime.strptime(txt, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def periodo_em_segundos(cron):
    """
    Quanto tempo, mais ou menos, entre duas execucoes.

    ⚠️ E uma ESTIMATIVA, e de proposito: interpretar cron de verdade exigiria
    uma biblioteca que a VM nao tem, e o numero exato nao muda a resposta. O
    que se quer saber e "faz tempo demais?", e para isso basta a ordem de
    grandeza -- minuto, hora, dia ou semana.

    Erra para o lado seguro: na duvida, supoe intervalo MAIOR, o que atrasa o
    alarme em vez de dispara-lo a toa. Alarme que grita sem motivo e o comeco
    de todo mundo ignorar o painel.
    """
    campos = cron.split()
    if len(campos) < 5:
        return 86400
    minuto, hora, dia, mes, semana = campos[:5]
    if minuto.startswith("*"):
        return 60
    if hora.startswith("*"):
        return 3600
    if dia == "*" and mes == "*" and semana == "*":
        return 86400
    return 7 * 86400


def kubectl(*args):
    saida = subprocess.run(KUBECTL + list(args), capture_output=True, text=True, timeout=60)
    if saida.returncode != 0:
        raise RuntimeError(saida.stderr.strip()[:200])
    return json.loads(saida.stdout)


def falhas_recentes(jobs, nome, ns):
    """Quantas execucoes concretas falharam, entre as que o cluster ainda guarda."""
    n = 0
    for j in jobs:
        m = j["metadata"]
        if m["namespace"] != ns:
            continue
        # O Job criado por um CronJob se chama `<cronjob>-<carimbo>`.
        if not re.fullmatch(re.escape(nome) + r"-\d+", m["name"]):
            continue
        if (j.get("status") or {}).get("failed"):
            n += 1
    return n


def main():
    try:
        cronjobs = kubectl("get", "cronjob", "-A", "-o", "json")["items"]
        jobs = kubectl("get", "job", "-A", "-o", "json")["items"]
    except Exception as e:
        # ⚠️ Escreve o ERRO no arquivo em vez de deixar o anterior no lugar.
        #
        # 🐞 Um coletor que morre calado deixa o painel exibindo a leitura de
        # ontem como se fosse de agora -- e "tudo verde, ha 14 horas" e
        # exatamente o que se ve quando esta tudo quebrado.
        gravar({"quando": agora().isoformat(), "erro": str(e), "tarefas": []})
        return 1

    tarefas = []
    for c in cronjobs:
        m, spec, st = c["metadata"], c["spec"], c.get("status", {})
        periodo = periodo_em_segundos(spec["schedule"])
        disparo = instante(st.get("lastScheduleTime"))
        sucesso = instante(st.get("lastSuccessfulTime"))
        suspenso = bool(spec.get("suspend"))

        sem_disparar = (agora() - disparo).total_seconds() if disparo else None
        sem_acertar = (agora() - sucesso).total_seconds() if sucesso else None

        # A margem e generosa (3x o periodo, com piso de 5 min) porque o
        # disparo do Kubernetes tem folga propria e a maquina divide CPU com a
        # esteira. Apertar isto encheria o painel de vermelho passageiro.
        margem = max(3 * periodo, 300)

        if suspenso:
            estado = "suspenso"
        elif sucesso is None:
            estado = "nunca"
        elif sem_acertar > margem:
            # roda e falha, ou parou de rodar -- os dois aparecem aqui, e o
            # `semDispararS` abaixo separa um do outro na tela
            estado = "atrasado"
        else:
            estado = "ok"

        tarefas.append({
            "nome": m["name"],
            "ns": m["namespace"],
            "agenda": spec["schedule"],
            "estado": estado,
            "suspenso": suspenso,
            "ultimoDisparo": st.get("lastScheduleTime"),
            "ultimoSucesso": st.get("lastSuccessfulTime"),
            "semDispararS": None if sem_disparar is None else int(sem_disparar),
            "semAcertarS": None if sem_acertar is None else int(sem_acertar),
            "periodoS": periodo,
            "falhasGuardadas": falhas_recentes(jobs, m["name"], m["namespace"]),
        })

    # Pior primeiro: quem abre o painel quer ver o problema, nao rolar ate ele.
    ordem = {"nunca": 0, "atrasado": 1, "suspenso": 2, "ok": 3}
    tarefas.sort(key=lambda t: (ordem[t["estado"]], t["ns"], t["nome"]))

    gravar({"quando": agora().isoformat(), "erro": None, "tarefas": tarefas})
    return 0


def gravar(dados):
    # Grava ao lado e RENOMEIA: renomear e atomico no mesmo sistema de
    # arquivos, entao o painel nunca le um JSON pela metade.
    tmp = DESTINO + ".novo"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(dados, f, ensure_ascii=False)
    import os
    os.replace(tmp, DESTINO)


if __name__ == "__main__":
    sys.exit(main())

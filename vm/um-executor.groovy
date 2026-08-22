/*
 * ===========================================================================
 * UM executor no Jenkins, e nao dois.
 *
 * Instalar em: /var/lib/jenkins/init.groovy.d/10-um-executor.groovy
 * ---------------------------------------------------------------------------
 * 🐞 POR QUE
 * ---------------------------------------------------------------------------
 * Esta VM roda PRODUCAO e CI no mesmo hardware. Em 22/08/2026 a carga chegou a
 * `load average 40` com 8 nucleos, e os 20 dominios de producao passaram a
 * devolver 502 -- com as aplicacoes respondendo 200 POR DENTRO. Faltou CPU para
 * o cloudflared atender, e o SSH tambem parou.
 *
 * Com dois executores, duas construcoes pesadas (Maven + Sonar + docker build)
 * rodam ao mesmo tempo. Cada uma sozinha ja disputa CPU com quem esta no ar;
 * duas juntas dobram a aposta.
 *
 * ⚠️ Isto NAO substitui separar as maquinas. Serializar reduz o PICO; produção
 * e construcao continuam no mesmo ferro, e um build sozinho ainda compete.
 *
 * ⚠️ E nao deixa a fila mais lenta do que parece: com dois executores as duas
 * builds terminavam em ~2x o tempo cada, por disputarem o mesmo disco e a mesma
 * CPU. Em serie, cada uma roda na velocidade cheia.
 *
 * Junto com a guarda de carga no `Preparo` de cada esteira (que espera a carga
 * cair abaixo de 2x os nucleos), o CI deixa de conseguir afogar producao.
 * ===========================================================================
 */
import jenkins.model.Jenkins

def inst = Jenkins.get()
if (inst.getNumExecutors() != 1) {
    inst.setNumExecutors(1)
    inst.save()
    println('  executores ajustados para 1')
} else {
    println('  ja estava em 1 executor')
}

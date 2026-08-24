/*
 * ===========================================================================
 * Cria as VISOES do Jenkins que mostram todos os projetos numa tela so.
 *
 *   sudo -u jenkins ... ou pela API:  POST /scriptText
 *
 * ---------------------------------------------------------------------------
 * POR QUE ISTO EXISTE
 * ---------------------------------------------------------------------------
 * Todo projeto aqui e um "multibranch": na tela inicial aparece a PASTA, e o
 * job de verdade (`main`) esta um clique adentro. Com dez projetos, saber o
 * estado geral custa dez cliques -- e e por isso que ninguem olha.
 *
 * ⚠️ A visao lista os jobs `main` DIRETAMENTE, atravessando as pastas
 * (`recurse = true`). E o filtro e por REGEX no nome completo, entao projeto
 * novo entra sozinho, sem precisar editar nada.
 * ===========================================================================
 */
import hudson.model.ListView
import jenkins.model.Jenkins

def inst = Jenkins.get()

// ---------------------------------------------------------------------------
// "Todas as esteiras" -- os jobs `main` de todos os projetos, lado a lado.
// ---------------------------------------------------------------------------
def nome = 'Todas as esteiras'
def v = inst.getView(nome)
if (v == null) {
    v = new ListView(nome, inst)
    inst.addView(v)
    println("  visao '${nome}' criada")
} else {
    println("  visao '${nome}' ja existia -- atualizando")
}

v.setRecurse(true)

// ⚠️ `.*/main$` e nao `main`: o nome COMPLETO de um job multibranch e
// `<projeto>/main`. Filtrar so por `main` nao casa com nada.
v.setIncludeRegex('.*/main$')

// As colunas que respondem "esta rodando? passou? ha quanto tempo?" sem clicar.
v.getColumns().clear()
v.getColumns().addAll(ListView.getDefaultColumns())

v.save()
println("  filtro: .*/main\$   |   jobs visiveis: ${v.getItems().size()}")

// ---------------------------------------------------------------------------
// "Painel" -- a MESMA lista, com o nome que o mural procura.
// ---------------------------------------------------------------------------
//
// 🐞 O painel em `userContent/painel/` busca `view/Painel/api/json`. Sem uma
// visao com ESSE nome, a chamada devolve 404 e o mural abre VAZIO -- sem erro
// na tela, sem nada no console. Foi assim que ele "nao renderizou" antes.
//
// ⚠️ Duas visoes com o mesmo filtro nao e duplicacao a toa: uma e para OLHAR
// no Jenkins, a outra e uma API que o mural consome. Renomear qualquer uma
// quebra algo em silencio.
def nomePainel = 'Painel'
def vp = inst.getView(nomePainel)
if (vp == null) {
    vp = new ListView(nomePainel, inst)
    inst.addView(vp)
    println("  visao '${nomePainel}' criada")
}
vp.setRecurse(true)
vp.setIncludeRegex('.*/main$')
vp.save()
println("  visao '${nomePainel}': ${vp.getItems().size()} job(s)")

// ---------------------------------------------------------------------------
// A visao vira a INICIAL, para ser o que se ve ao abrir o Jenkins.
// ---------------------------------------------------------------------------
inst.setPrimaryView(v)
inst.save()
println("  definida como visao inicial")

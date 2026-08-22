/*
 * ===========================================================================
 * Politica de seguranca dos arquivos servidos em /userContent.
 *
 * Instalar em: /var/lib/jenkins/init.groovy.d/20-csp-do-painel.groovy
 *
 * ---------------------------------------------------------------------------
 * 🐞 POR QUE AQUI, E NAO EM JAVA_OPTS
 * ---------------------------------------------------------------------------
 * A primeira tentativa pos a propriedade num `Environment="JAVA_OPTS=..."` do
 * systemd. O valor de uma politica CSP TEM espacos entre as diretivas, e o
 * systemd nao re-interpreta aspas: a linha de argumentos foi partida e o Java
 * leu a primeira palavra solta como nome de classe.
 *
 *     Error: Could not find or load main class none
 *     Caused by: java.lang.ClassNotFoundException: none
 *
 * ⚠️ E o Jenkins nao subiu mais -- ficou em ciclo de reinicio ate o systemd
 * desistir. A mensagem culpa uma classe chamada `none`, que e so o pedaco
 * `'none';` da politica virando argumento solto.
 *
 * Aqui nao ha linha de comando para partir: a propriedade e definida DENTRO da
 * JVM que ja esta rodando.
 *
 * ---------------------------------------------------------------------------
 * ⚠️ A POLITICA E ESTREITA DE PROPOSITO
 * ---------------------------------------------------------------------------
 * `script-src 'self'` libera script vindo de ARQUIVO servido pelo proprio
 * Jenkins, e NAO libera `unsafe-inline`.
 *
 * A diferenca importa: com `unsafe-inline`, qualquer HTML deixado em
 * `/userContent` -- inclusive relatorio gerado por build -- passaria a executar
 * script embutido com a sessao de quem abrir. Do jeito que esta, so codigo ja
 * gravado como arquivo naquela pasta roda, e gravar ali exige administrador.
 * ===========================================================================
 */
def politica = "default-src 'none'; script-src 'self'; style-src 'self'; " +
               "img-src 'self' data:; connect-src 'self'; font-src 'self'; " +
               "form-action 'none'; base-uri 'none'"

System.setProperty('hudson.model.DirectoryBrowserSupport.CSP', politica)
println('  CSP do /userContent definida: ' + politica)

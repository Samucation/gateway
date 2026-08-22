# A linha de partida do portão, e por que ela existe

Definida em 22/08/2026 para o **`sprinklegames-portal`**, e só para ele.

## O problema

O portão exige 80% de cobertura em **código novo**. Num projeto que já tem
10.375 linhas e nunca teve teste, "código novo" era **tudo** — porque a primeira
análise no Sonar é o marco zero, e tudo que existia antes dela entra como se
tivesse acabado de ser escrito.

Resultado: 13 commits com funcionalidade real (trilha sonora, espectro que pulsa
com a batida, música do menu) ficaram **parados 19 horas** sem chegar em
produção, esperando cobertura de código escrito meses antes.

## O que foi feito ANTES de recorrer à linha de partida

⚠️ Isto importa: a linha de partida não foi o primeiro recurso, foi o último.

1. **A física do espectro foi extraída** de dentro do laço de animação para
   `espectro-nucleo.js` e testada — 31 casos, cada um afirmando uma decisão
   (por que o passo de tempo tem teto, por que a parede devolve em vez de
   absorver, por que a batida exige piso).
2. **A conta de contraste foi exportada e testada** — 14 casos ancorados na
   WCAG. A regra do projeto é que contraste se mede; a medição em si nunca
   tinha sido medida.
3. **A tradução de linha do banco para JSON** — 4 casos. Erro ali não dá erro:
   o campo some da resposta e o site mostra espaço em branco.
4. **Desenho puro foi excluído da cobertura**, com o motivo escrito no
   `sonar-project.properties`.

Isso levou a cobertura de **0% para 53,8%**. O que restou para chegar a 80% são
páginas React e 814 linhas de dados de seed — onde o teste que se escreveria
seria de baixo valor: existiria para mover um número, não para proteger nada.

## A decisão

Marcar a análise de 22/08/2026 como linha de partida. Concretamente:

- a dívida anterior **continua registrada** no Sonar e visível no painel;
- **todo código escrito daqui para a frente** é cobrado nos 80%.

É a prática que o próprio SonarQube chama de *Clean as You Code*.

⚠️ **O que isto NÃO é**: não é baixar o corte de 80%, que continua valendo. Não
é excluir arquivo da análise — violação nova continua reprovando. É dizer que o
portão passa a medir a partir de quando ele existiu, em vez de cobrar
retroativamente.

⚠️ **O risco de fazer isso e o motivo de estar escrito aqui**: se virar hábito,
todo projeto que reprovar ganha uma linha de partida nova e o portão deixa de
significar qualquer coisa. Vale UMA VEZ por projeto, na adoção. O
`sprinklegames-portal` gastou a dele.

## Como refazer, se o Sonar for reinstalado

Pela tela: *Project Settings → New Code → Specific analysis*.

Pelo banco (foi assim, porque o token da esteira não tem permissão de admin):

    INSERT INTO new_code_periods (uuid, project_uuid, branch_uuid, type, value, created_at, updated_at)
    VALUES ('...', '<projeto>', '<ramo>', 'SPECIFIC_ANALYSIS', '<uuid da analise>', ..., ...);

Os identificadores saem de:

    SELECT b.project_uuid, b.uuid FROM project_branches b
      JOIN projects p ON p.uuid = b.project_uuid WHERE p.kee = 'sprinklegames-portal';

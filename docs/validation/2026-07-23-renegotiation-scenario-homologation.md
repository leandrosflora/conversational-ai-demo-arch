# Homologação do processo de renegociação — cenários por CPF — 2026-07-23

Execução real dos 10 cenários de `docs/homologacao/massa-de-teste-clientes.md` contra o agente
real de `agent-runtime-renegotiation` (`MOCK_AGENT_ENABLED=false`, `gpt-4o-mini`), com o
`core-bancario-mock` já atualizado com a tabela de cenários por CPF (change OpenSpec
`validate-renegotiation-flow-scenarios`).

## Resumo

**3 de 10 cenários totalmente verificados como esperado (0000, 3333, 9999). 1 com divergência
confirmada (6666). 6 parcialmente verificados** (1111, 2222, 4444, 5555, 7777, 8888 — etapa de
leitura/elegibilidade/simulação confirmada; etapa de confirmação/documento não pôde ser testada com
segurança — ver achado crítico #1). A camada de dados (`core-bancario-mock`) foi
verificada 100% correta de forma independente, via chamadas HTTP diretas (não dependem do agente)
— achados #1 e #2 abaixo são do `agent-runtime-renegotiation`/`tool-service-renegotiation`, não da
tabela de cenários adicionada por esta change.

| # | CPF | Cenário | Resultado |
|---|---|---|---|
| 0 | `00000000000` | Cliente não encontrado | ✅ Verificado |
| 1 | `11111111111` | Fluxo feliz padrão | ⚠️ Parcial (simulação ok; confirmação bloqueada — achado #1) |
| 2 | `22222222222` | Múltiplos contratos e dívidas | ⚠️ Parcial (identificação ok; confirmação não testada) |
| 3 | `33333333333` | Inelegível por inadimplência crítica | ✅ Verificado |
| 4 | `44444444444` | Dívida de baixo valor / pouco atraso | ⚠️ Parcial (simulação ok; confirmação não testada) |
| 5 | `55555555555` | Dívida alta / atraso severo | ⚠️ Parcial (simulação ok; confirmação não testada) |
| 6 | `66666666666` | Sem dívida em aberto | ❌ **Divergência** — achado #2 |
| 7 | `77777777777` | Simulação expira antes da confirmação | ⚠️ Parcial (simulação ok, mas com achado #3; expiração não testada) |
| 8 | `88888888888` | Documento pendente após confirmação | ⚠️ Parcial (simulação ok; confirmação/documento não testados) |
| 9 | `99999999999` | Parcelamento fora do range solicitado | ✅ Verificado |

## Ambiente e método

- Stack local via `docker compose up -d` (18 containers, incluindo os 7 serviços de aplicação),
  `core-bancario-mock` reconstruído com a tabela de cenários desta change antes de subir.
- `MOCK_AGENT_ENABLED=false`, `OPENAI_API_KEY` real, `OPENAI_MODEL_ID=gpt-4o-mini`, já configurados
  no `.env` do ambiente reutilizado.
- **Desvio do plano original**: em vez de enviar webhooks assinados via `whatsapp-bff` (que exigiria
  reconstruir a entrega de saída via WhatsApp Cloud API real — já documentado como indisponível
  localmente pela validação `2026-07-13-validate-e2e-microservices-journey`, "Drift documentado,
  comportamento entendido"), chamei `POST /process` de `agent-runtime-renegotiation` diretamente,
  mintando tokens internos JWT HS256 com os mesmos segredos que `conversation-orchestrator` usaria
  (par emissor/audiência `conversation-orchestrator`→`agent-runtime-renegotiation` e
  →`conversation-memory-service`, lidos do `.env` local). Isso exercita exatamente a mesma cadeia
  real (agente OpenAI → MCP `tool-service-renegotiation` → `renegotiation-service` →
  `core-bancario-mock`) que a jornada completa exercitaria, só pulando o transporte
  webhook→Kafka→Orchestrator→BFF-de-saída, que já tinha sido validado separadamente e cujo trecho
  final (entrega real ao WhatsApp) é uma limitação de ambiente conhecida e não relacionada aos
  cenários de negócio aqui testados.
- Para simular a continuidade de conversa que `conversation-orchestrator` normalmente mantém, cada
  mensagem do "cliente" e cada resposta do agente foram gravadas manualmente em
  `conversation-memory-service` (`POST /conversations/{id}/messages`) entre turnos.
- `JourneyStage` foi informado manualmente por chamada (não haviamos com o `conversation-orchestrator`
  real gerenciando a máquina de estados): `SimulationParametersPending` para o turno de
  identificação+elegibilidade+simulação (estágio que libera `consultar_cliente`, `consultar_contratos`,
  `validar_elegibilidade` e `simular_proposta` numa única chamada), e `ConfirmationPending` para a
  tentativa de confirmação (ver achado #1 sobre por que isso não é suficiente).

## Achados críticos (não corrigidos nesta change — reportados para follow-up)

### 1. Loop descontrolado no turno de confirmação (severidade: crítica)

Ao testar a confirmação do cenário 1111 (`JourneyStage=ConfirmationPending`,
`ExplicitConfirmationMessageId` preenchido, texto "Sim, confirmo o acordo..."), o agente entrou em
loop chamando `confirmar_acordo`/`gerar_documento` repetidamente — **mais de 110 chamadas de
ferramenta**, cada uma precedida de uma chamada real à API da OpenAI, sem nunca retornar uma
decisão. Foi necessário reiniciar o container `agent-runtime-renegotiation` manualmente para
interromper (consumo real de cota OpenAI acima do normal de qualquer outro turno testado).

**Causa raiz identificada no código** (não é específico de CPF/cenário, é estrutural):

- `ProcessRequest` (`agent-runtime-renegotiation/app/models.py`) não tem campo para carregar um
  `simulation_id` de um turno anterior.
- `conversation-memory-service` só persiste `role` + `content.text` (texto legível ao cliente); o
  `simulation_id` bruto nunca é falado na resposta ao cliente, logo nunca fica disponível em
  turnos seguintes.
- `tool-service-renegotiation/app/policy.py`: `SIMULATION_STAGES =
  {ContractSelected, EligibilityChecked, SimulationParametersPending}` e `CONFIRMATION_STAGES =
  {ProposalSelected, ConfirmationPending}` são **conjuntos disjuntos por desenho** (a regra "não
  formalizar sem confirmação explícita" exige turnos separados para simular e confirmar).
- Resultado: no turno de confirmação, o agente nunca tem um `simulation_id` válido para passar a
  `confirmar_acordo` — e, em vez de desistir ou sinalizar transferência humana após a negativa da
  política, o loop do agente (via SDK Strands, sem limite de iterações configurado em
  `agent-runtime-renegotiation/app/agent/core.py`) fica retentando indefinidamente.

**Impacto**: com o design atual, não há caminho visível (mensagem de chat ou "memory facts", que
existe como endpoint em `conversation-memory-service` mas não é usado em nenhum lugar do código de
`agent-runtime-renegotiation`) para o agente recuperar um `simulation_id` válido num turno
diferente daquele em que foi gerado. Isso bloqueou a homologação da etapa de confirmação/documento
para os 6 cenários que dependiam dela (1111, 2222, 4444, 5555, 7777, 8888) — a decisão de negócio
foi não repetir o teste nos demais cenários após confirmar a causa estrutural, para não incorrer em
mais custo de API em loops equivalentes.

**Sugestão para follow-up**: (a) adicionar um limite duro de iterações/tempo por chamada de
`agent.invoke_async` em `agent-runtime-renegotiation`, e (b) resolver como o `simulation_id`
sobrevive entre turnos — via `conversation-memory-service`'s endpoint de "memory facts"
(`PUT /users/{id}/memory`, já existe mas não é usado), via um novo campo no contrato de
`POST /process`, ou fundindo simulação+confirmação numa política de estágio compartilhado.

### 2. `consultar_debitos` nunca é chamado pelo agente (severidade: alta)

Em nenhum dos 10 cenários testados (0000 a 9999) o agente chamou a ferramenta `consultar_debitos`
— confirmado nos logs de `tool-service-renegotiation` (`Tool ... completed` nunca lista
`consultar_debitos` na sessão inteira). O agente sempre segue
`consultar_cliente → consultar_contratos → validar_elegibilidade → simular_proposta`, usando
apenas o `OutstandingAmount` do contrato (nunca os `DebtItem`s individuais) como "a dívida" nas
respostas.

**Consequência concreta**: no cenário 6666 (CPF `66666666666`, lista de dívidas vazia por desenho
— ver `renegotiation-scenario-fixtures`), o resultado esperado era o agente informar que não há
dívida em aberto para renegociar. Em vez disso, o agente simulou e ofereceu uma proposta normal
("12 parcelas de R$ 83,33, totalizando R$ 1.000") baseada só no contrato existir, ignorando que
não há débito real associado — **contradiz diretamente a regra do system prompt "Nunca invente
valores... use sempre as ferramentas disponíveis para consultar informações reais do cliente"**,
já que ele nunca consultou o débito antes de simular.

**Sugestão para follow-up**: tornar `consultar_debitos` obrigatório (não "quando necessário") no
system prompt antes de `simular_proposta`, ou fazer `simular_proposta`/`validar_elegibilidade` no
`core-bancario-mock`/`renegotiation-service` recusarem simulação quando a lista de dívidas do
contrato estiver vazia (defesa em profundidade, já que depender só do prompt é frágil).

## Achados menores

### 3. `simular_proposta` chamado várias vezes na mesma resposta (severidade: baixa)

O system prompt instrui "chame simular_proposta no máximo uma vez por contrato nesta resposta".
Observado: cenário 7777 chamou `simular_proposta` **4 vezes** (12x, 6x-50%desc, 3x-25%desc,
12x-75%desc) na mesma resposta sem que o cliente tivesse pedido comparação; cenário 9999 chamou
**5 vezes** (justificável nesse caso — precisava achar parcelas válidas após 60x ser rejeitado, mas
ainda acima do texto literal da regra). Não corrigido nesta change; efeito é custo/latência extra,
não incorreção de resposta.

### 4. Valor simulado do `core-bancario-mock` não deriva do valor real da dívida (severidade: informativa, pré-existente)

`core-bancario-mock`'s `POST /contracts/{contractId}/simulations` usa uma base fixa de R$ 1.000,00
(`const decimal baseAmount = 1000m`) independente do `OutstandingAmount`/dívida real do cliente —
comportamento que já existia antes desta change, não introduzido pela tabela de cenários. Observado
concretamente no cenário 4444 (dívida de R$ 85,00 real, mas proposta apresentada de "R$ 850,00
total a pagar com 15% de desconto") — o discurso do agente ("desconto de 15% sobre o valor da
dívida original") fica logicamente inconsistente com os valores reais. Fora do escopo desta change
corrigir (é `core-bancario-mock`, mas não faz parte da tabela de cenários adicionada), reportado
para visibilidade caso a homologação de negócio se importe com valores simulados plausíveis.

## Resultado por cenário

### 0 — `00000000000` — Cliente não encontrado — ✅ Verificado
Resposta: *"Parece que o CPF informado não está cadastrado em nosso sistema... recomendo entrar em
contato com um atendente humano."* `RequiresHandoff=true`, `HandoffReason="CPF não encontrado no
sistema."`. Ferramentas chamadas: `consultar_cliente` (único). Bate com o esperado.

### 1 — `11111111111` — Fluxo feliz padrão — ⚠️ Parcial
Turno 1 (`JourneyStage=SimulationParametersPending`): agente consultou cliente, contratos,
elegibilidade e simulou (12x de R$ 66,67, total R$ 800 com 20% desconto) numa única resposta,
perguntando se o cliente quer formalizar. Bate com o esperado. Turno 2 (confirmação): bloqueado
pelo achado crítico #1 — não foi possível completar.

### 2 — `22222222222` — Múltiplos contratos e dívidas — ⚠️ Parcial
Turno 1: agente identificou os 2 contratos (empréstimo R$ 6.000 e cartão R$ 3.200), chamou
`validar_elegibilidade` para ambos, e perguntou qual o cliente quer renegociar primeiro — sem
simular sem essa definição. Bate com o esperado. Confirmação não testada (decisão de escopo após
achado #1).

### 3 — `33333333333` — Inelegível por inadimplência crítica — ✅ Verificado
Resposta explicou a inelegibilidade citando "inadimplente crítico" e ofereceu transferência para
atendimento humano (`RequiresHandoff=true`). Confirmado nos logs: agente parou em
`validar_elegibilidade`, **não** chamou `simular_proposta` — respeitou a regra de negócio de não
simular para cliente inelegível. Bate com o esperado.

### 4 — `44444444444` — Dívida de baixo valor / pouco atraso — ⚠️ Parcial
Turno 1: simulação oferecida normalmente (12x de R$ 141,67, total R$ 850,00) mesmo com valor baixo
— fluxo não foi bloqueado pelo valor pequeno, como esperado. Ver achado #4 sobre a inconsistência
do valor simulado. Confirmação não testada.

### 5 — `55555555555` — Dívida alta / atraso severo — ⚠️ Parcial
Turno 1: simulação oferecida normalmente (12x de R$ 66,67, total R$ 800,00), sem tratamento
diferenciado nem recusa por valor/atraso altos. Confirmação não testada.

### 6 — `66666666666` — Sem dívida em aberto — ❌ Divergência confirmada
Esperado: informar que não há dívida para renegociar. Observado: agente simulou e ofereceu uma
proposta normal sem nunca consultar as dívidas (achado #2). **Divergência real**, não corrigida
nesta change (fora de escopo — é um comportamento do agente, não do `core-bancario-mock`, cujos
dados retornam a lista de dívidas vazia corretamente, confirmado via `curl` direto na tarefa 1.9).

### 7 — `77777777777` — Simulação expira antes da confirmação — ⚠️ Parcial
Turno 1: simulação apresentada (com o achado #3 de repetição excessiva). Etapa de expiração na
confirmação não testada (decisão de escopo após achado #1) — o comportamento do
`core-bancario-mock` para este cenário (gera `simulationId` com sufixo `-expired`, negando a
confirmação subsequente) já foi verificado diretamente via `curl` na tarefa 1.9, fora do agente.

### 8 — `88888888888` — Documento pendente após confirmação — ⚠️ Parcial
Turno 1: simulação limpa, uma única chamada (12x de R$ 70,83, total R$ 850,00). Etapa de
confirmação/documento pendente não testada via agente (decisão de escopo após achado #1) — o
comportamento do `core-bancario-mock` (agreementId com sufixo `-pendente`, documento
`document_not_ready`) já foi verificado diretamente via `curl` na tarefa 1.9.

### 9 — `99999999999` — Parcelamento fora do range solicitado — ✅ Verificado
Cliente pediu 60x; agente identificou que não é possível e ofereceu alternativas dentro do range
(48x, 36x, 24x, 12x, todas com total R$ 1.000,00 sem desconto). Bate com o esperado — a mensagem
de negócio central (recusa educada + alternativas válidas) está correta, apesar do achado menor #3
sobre número de chamadas.

## Não verificado nesta rodada

- Etapa de confirmação (`confirmar_acordo`) e geração de documento (`gerar_documento`) via agente
  real, para os 6 cenários que dependem dela — bloqueado pelo achado crítico #1. O comportamento
  do `core-bancario-mock` nessas etapas foi verificado independentemente (fora do agente) na tarefa
  1.9 de `openspec/changes/validate-renegotiation-flow-scenarios/tasks.md`.
- Entrega real da resposta via WhatsApp Cloud API (transporte `whatsapp-bff` → Graph API) — já
  documentado como indisponível localmente pela validação `2026-07-13-validate-e2e-microservices-journey`,
  não re-testado aqui por não fazer parte do escopo de negócio desta homologação.
- Comportamento sob `MOCK_AGENT_ENABLED=true` (não é o objetivo desta homologação, que exige
  raciocínio real).

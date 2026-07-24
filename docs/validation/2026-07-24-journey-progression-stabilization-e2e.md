# Estabilização da progressão de jornada (`JourneyMilestone`) — E2E — 2026-07-24

Validação end-to-end da change OpenSpec `stabilize-renegotiation-journey-progression`, motivada
pelo cliente CPF `22222222222` (múltiplos contratos) ficando permanentemente preso no fluxo real de
WhatsApp — o agente repetia "vamos continuar" e admitia não conseguir prosseguir "devido ao estágio
atual da jornada". Esta rodada substitui o achado crítico #1 de
`2026-07-23-renegotiation-scenario-homologation.md` (loop descontrolado no turno de confirmação):
a causa raiz ali identificada (progressão de `JourneyStage` dependente do texto livre e
não-confiável `Intent` do modelo) foi corrigida por este change.

## Resumo

**Jornada completa verificada end-to-end, via chamadas reais a `POST /messages` do
`conversation-orchestrator`** (não `POST /process` do agent-runtime diretamente como na rodada
anterior — desta vez o `conversation-orchestrator` real gerencia toda a máquina de estados), para os
dois cenários reservados relevantes:

| CPF | Cenário | Resultado |
|---|---|---|
| `11111111111` | Contrato único, fluxo feliz | ✅ `Started → CustomerIdentified → ContractSelected → EligibilityChecked → ProposalAvailable → ProposalSelected → AgreementConfirmed → DocumentAvailable` |
| `22222222222` | Múltiplos contratos | ✅ `Started → CustomerIdentified → ContractSelectionPending → ContractSelected → EligibilityChecked → ProposalAvailable → ProposalSelected → AgreementConfirmed → DocumentAvailable` |

Ambos alcançaram `DocumentAvailable` com link de documento real (`gerar_documento` bem-sucedido).
Nenhuma etapa exigiu reinício manual por loop (ao contrário do achado crítico #1 de 23/07) —
cada turno retornou uma decisão em poucos segundos.

Três bugs adicionais foram descobertos e corrigidos durante esta rodada (nenhum estava presente na
proposta original da change; todos confirmados ao vivo antes e depois da correção):

1. **`_override_handoff_for_stage_denial` exigia sucesso no mesmo turno** para limpar um
   `requires_handoff` incorreto — quebrava exatamente no turno em que o cliente aceita a proposta em
   texto livre ("Aceito essa proposta"), já que o `JourneyStage` só avança *depois* que o turno
   termina, então a tentativa prematura de `confirmar_acordo` do agente é negada sem nenhum sucesso
   naquele turno. Corrigido: a condição não exige mais sucesso, apenas que toda falha do turno seja
   negação por estágio.
2. **Nenhuma instrução no system prompt para chamar `gerar_documento`** — após `confirmar_acordo`
   ter sucesso, o agente ficava re-tentando `confirmar_acordo` (negado) em vez de gerar o documento
   quando o cliente pedia. Corrigido com uma regra explícita no prompt.
3. `consultar_contratos` foi chamado pelo modelo com um `client_id` truncado (ex: `"1111"`/`"2222"`
   em vez do CPF completo) em 2 das 3 tentativas de fluxo completo, e
   `renegotiation-service`/`core-bancario-mock` aceitava silenciosamente o identificador incorreto,
   retornando dados de um cliente diferente em vez de erro. Inicialmente registrado aqui como
   "não corrigido, fora de escopo" — **revisto e corrigido** depois que um teste real de cliente via
   WhatsApp (seção abaixo) mostrou que esse mesmo bug causa dados financeiros incorretos, não é só
   cosmético. Ver seção "Teste real de cliente via WhatsApp".

**Duas rodadas adicionais de correção**, motivadas por um teste real de cliente via WhatsApp
conduzido pelo usuário logo após a rodada acima (mesmo dia) — ver seção dedicada abaixo:

4. **Resolução de `ContractSelectionPending → ContractSelected` não disparava com resposta curta do
   cliente** (ex: `"2"`) — o agente tentava consultar débitos/elegibilidade diretamente em vez de
   re-confirmar o contrato via `consultar_contratos`, ficando preso indefinidamente. Corrigido com
   regra explícita no prompt.
5. **`core-bancario-mock` fabricava dados plausíveis para identificadores malformados** (ex: CPF
   truncado "2222") em vez de retornar erro — permitindo que uma renegociação prosseguisse com saldo/
   dívida fabricados em vez dos reais do cliente. Corrigido validando o formato do CPF (11 dígitos)
   antes de gerar dados genéricos ou consultar o cenário reservado.

## Ambiente e método

- Stack local via `docker compose up -d`, mesma stack da rodada de 23/07.
- `agent-runtime-renegotiation` reconstruído e reiniciado 3 vezes nesta rodada, uma por correção
  aplicada (mapeamento `confirmar_acordo → AgreementConfirmed`, relaxamento do override de handoff,
  regra de prompt para `gerar_documento`).
- **Diferença chave da rodada de 23/07**: desta vez as chamadas foram feitas contra
  `POST /messages` do `conversation-orchestrator` real (porta 5268), com tokens internos JWT
  HS256 mintados no par emissor/audiência `whatsapp-bff`→`conversation-orchestrator`. Isso exercita
  a máquina de estados real (`JourneyStage` persistido em `ops.conversation_state`,
  `JourneyMilestone` computado pelo agent-runtime e aplicado pelo orchestrator) em vez de simular o
  estado manualmente — validação mais fiel ao comportamento real de produção que a rodada anterior.
- Script auxiliar: `scratchpad/e2e_orchestrator.sh` (`send_message CONVERSATION_ID MESSAGE_ID TEXT`).
- Estado verificado após cada turno via `SELECT journey_stage, active_contract_id,
  active_simulation_id, active_agreement_id FROM ops.conversation_state WHERE conversation_id=...`
  e a última resposta via `SELECT payload FROM ops.orchestrator_outbox WHERE effect_type='channel.reply'`.
- Duas conversas foram abandonadas por contaminação de estado antes de se chegar às conversas finais
  reportadas acima: `e2e-fresh-1111` (ficou presa em `HandoffRequested` — ordinal 15, mais alto que
  qualquer estágio de negócio real, tornando-a irrecuperável pela checagem de legalidade
  "forward-only" do milestone — exatamente o bug #1 acima, testado *antes* da correção) e
  `e2e-fresh-3333` (contaminada pelo achado #3 de `client_id` truncado logo no turno 1/2, tornando a
  conversa confusa o suficiente para não valer a pena continuar). Ambas descartadas em favor de
  conversas novas, sem tentar "consertar" o estado já persistido — consistente com o comportamento
  esperado: uma vez que a jornada é corrompida por um bug real, a correção deve valer para novas
  conversas, não para reparar retroativamente conversas já corrompidas.

## Achados

### 1. Override de handoff exigia sucesso no mesmo turno (severidade: alta, corrigido)

`agent-runtime-renegotiation/app/agent/core.py`, `_override_handoff_for_stage_denial`: antes desta
correção, a condição era `any_success and any_stage_denied and not any_other_failure`. Ao vivo, em
`e2e-fresh-1111`, o cliente respondeu "Aceito essa proposta" com `journey_stage=ProposalAvailable`
ainda persistido (o avanço para `ProposalSelected` só acontece depois que o turno termina, via
`ProposalSelectionDetector` no lado do orchestrator). O agente tentou `confirmar_acordo` (negado —
estágio ainda não avançado) e, sem sucesso algum no turno, decidiu sozinho solicitar handoff. Como
não havia nenhum sucesso, o override não disparou, e o cliente recebeu: *"Neste estágio, não
consigo recalcular a proposta ou formalizar o acordo... Você gostaria de ser transferido para um
atendente?"* — reproduzindo exatamente o sintoma do bug original do screenshot, agora num ponto
diferente da jornada.

**Correção**: removida a exigência de sucesso; a condição passou a ser `any_stage_denied and not
any_other_failure`. Testes unitários atualizados (`test_override_handoff_for_stage_denial_keeps_handoff_when_nothing_succeeded`
renomeado e invertido para `..._clears_handoff_when_nothing_succeeded_but_all_denials_were_stage_gated`).
Suíte completa: 53/53. Verificado ao vivo em `e2e-fresh-4444`: mesmo turno, mesma mensagem, mesmo
estágio de entrada → resposta corrigida (*"Já confirmei parte do seu cadastro... pode me confirmar
que deseja seguir?"*) e `journey_stage` avançou corretamente para `ProposalSelected`.

### 2. `gerar_documento` inalcançável por falta de instrução no prompt (severidade: alta, corrigido)

Mesmo com o `JourneyMilestone` computando `AgreementConfirmed` corretamente após `confirmar_acordo`
bem-sucedido, o agente não sabia que devia chamar `gerar_documento` no turno seguinte. Ao pedir
explicitamente "Pode me enviar o documento do acordo?", o agente re-tentou `confirmar_acordo`
(negado, pois o acordo já estava confirmado) e nunca tentou `gerar_documento` — respondendo
apenas que "poderia" gerar o documento, pedindo confirmação novamente em vez de agir.

**Correção**: adicionada regra ao `SYSTEM_PROMPT` (`app/agent/prompts.py`): quando
`active_agreement_id` já está preenchido, não repetir `confirmar_acordo`; chamar `gerar_documento`
com esse identificador quando o cliente pedir o documento. Verificado ao vivo em `e2e-fresh-4444` e
`e2e-final-2222`: `gerar_documento` bem-sucedido na primeira tentativa após a correção, retornando
link real (`https://mock-documents.local/agreements/{id}.pdf`), `journey_stage=DocumentAvailable`.

### 3. `client_id` truncado aceito silenciosamente pelo mock (severidade: média, não corrigido — fora de escopo)

Em 2 das 3 tentativas completas de fluxo, o modelo chamou `consultar_contratos` com um `client_id`
truncado (`"1111"` ou `"2222"` em vez do CPF completo de 11 dígitos) — não em toda chamada, de forma
não-determinística. `renegotiation-service`/`core-bancario-mock` não validam que o `client_id`
recebido é um CPF válido/conhecido e retornam dados de *algum* cliente mesmo assim (200 OK), em vez
de erro. Isso não impediu a jornada de progredir corretamente (o `active_contract_id` resultante,
embora com prefixo truncado, permaneceu consistente com o cliente errado pelo resto da mesma
conversa — sem quebrar a máquina de estados), mas é uma divergência de dados real: o cliente
efetivamente renegocia sob um `contract_id` que não corresponde ao seu CPF informado.

**Sugestão para follow-up**: `core-bancario-mock`/`renegotiation-service` deveriam validar que
`client_id` recebido corresponde a um CPF cadastrado (11 dígitos) e retornar 404 para prefixos
parciais, em vez de responder 200 com dados de outro cliente. Separadamente, o system prompt
poderia reforçar "use sempre o CPF completo de 11 dígitos, nunca um prefixo" — mas validação
defensiva do lado do mock é mais robusta que depender só do prompt (mesmo padrão do achado #2 da
rodada de 23/07).

## Resultado por conversa

### `e2e-fresh-4444` — `11111111111` — ✅ Verificado completo
7 turnos (identificação → contrato → débitos+elegibilidade → simulação → aceite → confirmação →
documento), todos em turnos separados e pequenos (1-2 ferramentas por turno) para isolar cada
transição. `journey_stage` avançou exatamente como a tabela de milestones de `design.md` prevê em
cada turno. `active_contract_id`, `active_simulation_id`, `active_agreement_id` todos populados e
preservados corretamente entre turnos.

### `e2e-final-2222` — `22222222222` — ✅ Verificado completo (cenário original do bug)
8 turnos. Turno 2 listou os dois contratos (*"Empréstimo Pessoal - ID: 22222222222-contract-1...
Cartão de Crédito - ID: 22222222222-contract-2..."*) e perguntou qual o cliente queria tratar —
comportamento correto de `ContractSelectionPending`, sem chamar `consultar_debitos`/
`validar_elegibilidade`/`simular_proposta` prematuramente. Restante da jornada idêntica em forma ao
fluxo de contrato único. Confirmação final: *"Seu acordo foi confirmado com sucesso!"* com link de
documento.

## Teste real de cliente via WhatsApp (achados #4 e #5)

Após a rodada acima ser reportada como completa, o usuário conduziu um teste real via WhatsApp
(conversa `5511942302556`, CPF `22222222222`) e ainda ficou preso: o agente repetiu "não consigo
acessar... devido ao estágio atual da jornada" por vários turnos seguidos ao selecionar o contrato
de **Cartão de Crédito** com uma resposta curta ("2"). Investigação da transcrição real (via
`conversation_messages` do `conversation-memory-service`) e dos logs de `tool-service-renegotiation`
revelou dois bugs distintos, ambos corrigidos e verificados ao vivo no mesmo dia:

### 4. Resolução de `ContractSelectionPending` dependia de uma ação que o agente não tomava naturalmente

O caminho de resolução em `_contracts_milestone` (agent-runtime-renegotiation) já existia e já
funcionava - mas só quando o agente re-chamava `consultar_contratos` no mesmo turno em que o cliente
nomeava um contrato. Em todos os testes *roteirizados* desta rodada, a mensagem sempre reafirmava o
contrato explicitamente, então o agente fazia essa chamada naturalmente. Um cliente real respondendo
apenas `"2"` não levava o agente a re-consultar contratos - ele tentava `consultar_debitos`/
`validar_elegibilidade` diretamente, que ficavam bloqueados pelo estágio (ainda
`ContractSelectionPending`) indefinidamente, turno após turno.

**Correção**: regra explícita adicionada ao system prompt (`app/agent/prompts.py`) instruindo o
agente a sempre re-chamar `consultar_contratos` no turno em que o cliente nomeia um contrato, antes
de qualquer chamada de débitos/elegibilidade. Reproduzido ao vivo o turno exato do cliente real
(`e2e-real-repro`, conversa nova, mesma sequência: CPF → "quais contratos?" → **"2"**): antes da
correção, ficava preso em `ContractSelectionPending`; depois, avança para `ContractSelected` no
turno seguinte à resposta curta.

### 5. `core-bancario-mock` fabricava dados plausíveis para um CPF truncado

Ao verificar a correção acima, a re-consulta de contratos às vezes usava um `client_id` truncado
(`"2222"` em vez de `"22222222222"`) - o achado #3 da rodada anterior, agora com impacto real
confirmado: `core-bancario-mock` retornava **200 OK com um contrato fabricado** (cartão de crédito,
R$ 1.800,00 - visualmente plausível, mas não é o saldo real do cliente, R$ 3.200,00) em vez de erro,
porque qualquer identificador não reconhecido caía no gerador genérico de dados mock, sem validação
de formato.

**Correção**: `core-bancario-mock/Program.cs` agora valida que a porção CPF de qualquer identificador
(`clients/{cpf}`, `.../contracts`, `.../debts`, `.../eligibility`, `.../simulations`) tem exatamente
11 dígitos numéricos antes de gerar dados genéricos ou consultar o cenário reservado - caso
contrário, `404`. CPFs válidos mas não-reservados continuam funcionando exatamente como antes (dado
genérico plausível), só identificadores malformados passam a ser rejeitados. Reproduzido ao vivo em
`e2e-real-repro2` (conversa nova, sequência idêntica): antes da correção, `active_contract_id`
silenciosamente virava `2222-contract-2` com dados fabricados; depois, o identificador malformado
falha (`404`), o agente usa o CPF completo corretamente, e `active_contract_id` fica
`22222222222-contract-2` com débitos reais (R$ 900,00/R$ 500,00, batendo com
`ScenarioFixtures.ByCpf["22222222222"]`).

## Não verificado nesta rodada

- Reprodução do transporte real via WhatsApp Cloud API (mesma limitação de ambiente documentada em
  `2026-07-13-e2e-journey.md` e reafirmada em `2026-07-23-renegotiation-scenario-homologation.md`).
- Os demais 6 cenários da massa de teste (`33333333333` a `99999999999`) com a máquina de estados
  real do `conversation-orchestrator` — a rodada de 23/07 já verificou a camada de simulação/dados
  para todos eles via `POST /process` direto; esta rodada focou especificamente nos dois cenários
  relevantes ao bug que motivou a change (`11111111111` como controle de regressão,
  `22222222222` como o cenário original).
- Cancelamento (`RequestedCancellation`) via texto livre — `ProposalSelectionDetector` cobre apenas
  o caminho de aceite; a mesma lógica de detecção de cancelamento mencionada em `design.md` Decision
  5 não foi implementada nem testada nesta change (não fazia parte do sintoma relatado).

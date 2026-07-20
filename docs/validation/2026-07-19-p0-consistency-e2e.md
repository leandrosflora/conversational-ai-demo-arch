# Validação E2E pós-merge do P0 consistency policy (outbox transacional + governed tools) — 2026-07-19

Contexto: desde a última validação (`2026-07-18-p1-hardening-e2e.md`), a PR `agent/p0-consistency-policy` foi mesclada em 6 dos repos de aplicação (`conversation-orchestrator`, `agent-runtime-renegotiation`, `tool-service-renegotiation`, `renegotiation-service`, `knowledge-service`, `conversation-memory-service`, `conversational-ai-demo-arch`), introduzindo um outbox transacional no Orchestrator e uma política de "governed tools" (autorização por estágio de jornada) no `tool-service-renegotiation`. Esta rodada repete a mesma pergunta da validação anterior — **o ambiente sobe do zero e a jornada continua funcionando de ponta a ponta?** — desta vez sobre o código pós-merge.

Resposta curta: o ambiente sobe limpo (`docker compose up -d --build`, sem correções necessárias desta vez) e a jornada alcança a WhatsApp Cloud API real de ponta a ponta, mas **duas regressões de comportamento e uma quebra ampla de suítes de teste** foram encontradas, todas rastreáveis à mesma PR.

## Método

Stack subida via `docker compose up -d --build` com `MOCK_AGENT_ENABLED=false` e `OPENAI_API_KEY` real (mesmo método da rodada anterior). Dois turnos de uma conversa real foram enviados via webhook HMAC assinado contra `whatsapp-bff`, com um número de telefone sintético novo (`17865551234`, não usado em rodadas anteriores):

1. "Quero renegociar minha divida" — sem CPF ainda.
2. "Meu CPF eh 12345678900" — CPF de teste conhecido (`postman/local-docker-compose.postman_environment.json`).

## Jornada feliz — o que funcionou

| Etapa | Resultado |
|---|---|
| Handshake de verificação do webhook | **Confirmado** — `200 OK` |
| Webhook assinado (HMAC) → `whatsapp-bff` → Kafka → Orchestrator | **Confirmado** — `202 Accepted` em ambos os turnos |
| Orchestrator → Agent Runtime (JWT, OpenAI real) | **Confirmado** — turno 1 ~6.6s, turno 2 ~4s |
| Agent Runtime → `tool-service-renegotiation` → `renegotiation-service` → `core-bancario-mock` (`consultar_cliente`) | **Confirmado** — `GET /clients/12345678900` retornou `200 OK` |
| Orchestrator → `whatsapp-bff` (JWT) → WhatsApp Cloud API real | **Confirmado o alcance**; rejeitado pela Graph API real (`#131030 Recipient phone number not in allowed list`) — mesmo drift esperado da rodada de 18/07, número sintético não cadastrado |
| Tenant propagado (`00000000-0000-0000-0000-000000000001`) em todos os saltos | **Confirmado** |

## Regressões encontradas (novas desde 18/07, introduzidas pela PR de consistência P0)

### 1. `consultar_contratos` é negado pela política de "governed tools" no mesmo turno em que `consultar_cliente` acabou de identificar o cliente

A política em `tool-service-renegotiation/app/policy.py` (`READ_TOOL_STAGES`) só permite `consultar_contratos` a partir do estágio `CustomerIdentified` em diante, mas o `journey_stage` usado para autorizar chamadas de ferramenta é assinado **uma vez no início do turno** (`agent-runtime-renegotiation/app/tools/tool_service.py`, a partir de `payload.journey_stage` recebido do Orchestrator) e nunca é atualizado durante o turno. Confirmado em log: a conversa estava em `IdentificationPending` no início do turno 2; `consultar_cliente` foi permitido (está na lista de estágios) e teve sucesso (`GET /clients/12345678900` → `200 OK`), mas a chamada seguinte, `consultar_contratos`, foi negada (`outcome=error`) — nunca chegou a `renegotiation-service`, porque `IdentificationPending` não está no conjunto de estágios permitidos para essa ferramenta. O estágio só avança para `CustomerIdentified` depois que o turno inteiro termina e o Orchestrator persiste o resultado — tarde demais para a mesma chamada de agente que acabou de identificar o cliente.

Isso é uma regressão direta: a validação de 18/07 confirmou explicitamente `consultar_cliente`/`consultar_contratos` retornando `200 OK` **na mesma rodada**. Qualquer turno em que o LLM encadeie identificação + consulta de contratos — o padrão natural de uso — vai falhar na segunda chamada.

### 2. Efeito de outbox `channel.reply` entra em retry infinito quando o envio é permanentemente não-entregável

Quando `whatsapp-bff` rejeita um reply porque a WhatsApp Cloud API recusou o destinatário (`#131030`, número de teste não cadastrado), `whatsapp-bff` responde de forma correta e deliberada: `502` na primeira tentativa (falha ambígua, mantém a reserva de idempotência) e depois `409 Conflict` com `{"retryable": false, "reconciliationRequired": true}` nas tentativas seguintes (reserva já em andamento). Porém `conversation-orchestrator/Adapters/Outbound/Http/ChannelReplyClient.cs` ignora o corpo da resposta e chama `EnsureSuccessStatusCode()`, tratando qualquer não-2xx como falha transitória. O `OutboxDispatcherService` (`Adapters/Outbound/Persistence/OutboxDispatcherService.cs:72`) recalcula o backoff exponencial a cada falha (`2^min(attempt,8)`, capado em 300s) mas **não tem limite de tentativas nem caminho de dead-letter** — observado em produção local retentando em 2s, 4s, 8s, 16s, 32s, 64s… sem sinal de parar. Como `whatsapp-bff` já identificou e sinalizou explicitamente que a falha não é retryable, o Orchestrator deveria honrar esse sinal e marcar o efeito como falho-terminal em vez de retentar para sempre. Em produção, qualquer número permanentemente não-entregável (bloqueado, opt-out, inválido) geraria uma tentativa a cada 5 minutos indefinidamente, consumindo capacidade do dispatcher sem nunca alertar um operador.

### 3. Suítes de teste (.NET e pytest) quebradas pela mesma PR, não corrigidas antes do merge

| Repo | Resultado | Causa raiz observada |
|---|---|---|
| `conversation-orchestrator.Tests` | **67/73** (6 falhas, todas em `MessageIngestionEndpointsTests`) | Testes fazem `POST /messages` e verificam mocks (`IChannelReplyClient.SendReplyAsync`, auditoria, handoff) **sincronamente** logo após a chamada — mas esses efeitos agora são despachados de forma assíncrona pelo `OutboxDispatcherService` em background. Os testes não foram atualizados para o novo modelo transacional. |
| `renegotiation-service.Tests` | **29/35** (6 falhas — regressão vs. 35/35 confirmado em 18/07) | `SimulationEndpointsTests`/`FormalizationEndpointsTests` esperam `200 OK` e recebem `400`/`403` — indica contrato de autorização/validação mudou sem atualizar os testes. |
| `tool-service-renegotiation` (pytest) | **17/39** (22 falhas) | Combinação de (a) testes de ferramenta MCP que não configuram o `ToolExecutionContext`/tenant contextvar exigido pela nova `PlatformMiddleware` (`"Tenant context is not available"`), e (b) `TypeError` em `test_renegotiation_client.py` sugerindo assinatura de método mudou sem atualizar os testes. |

Os três achados de teste apontam para o mesmo padrão: a PR de consistência P0 mudou contratos de comportamento (dispatch assíncrono, autorização por estágio, tenant/contexto assinado) em três repos e não atualizou as suítes correspondentes antes do merge — exatamente o tipo de lacuna que os achados 1 e 2 acima expõem em runtime real.

## Não verificado nesta rodada

- Persistência em `conversation-memory-service` e `conversation-audit-service` não pôde ser confirmada via chamada direta à API (ambos exigem JWT interno; não gerei token para inspeção manual) — inferida apenas indiretamente pelos logs do Orchestrator despachando os efeitos `MemoryAppendMessage`/`MemorySaveSession`.
- Suítes pytest de `agent-runtime-renegotiation`, `knowledge-service` e `conversation-memory-service` não foram rodadas nesta rodada (mesmo escopo já não coberto em 18/07).
- Caminho de handoff completo e rotação de token JWT sob carga — mesmo não-verificado da rodada anterior, ainda não exercitado.

## Atualização — suítes de teste corrigidas em 19/07

Os 34 testes quebrados listados acima foram corrigidos (sem alterar comportamento de produção): `conversation-orchestrator.Tests` 73/73, `renegotiation-service.Tests` 35/35, `tool-service-renegotiation` pytest 39/39. Em todos os casos a correção foi atualizar o fixture/harness de teste para o novo contrato (dispatch assíncrono via outbox, token `governed_tool` assinado, `ToolExecutionContext`/tenant contextvar) em vez de mudar o código de produção — os achados 1 e 2 (regressões de comportamento) **continuam não corrigidos** e precisam de decisão de produto/arquitetura antes de mexer no código de produção.

## Recomendação

Achados 1 e 2 são bugs de comportamento (não apenas testes quebrados) e bloqueiam o uso realista da jornada com múltiplas chamadas de ferramenta por turno e o tratamento correto de falhas permanentes de entrega. Antes de considerar a PR de consistência P0 pronta para produção, sugiro: (a) tornar o `journey_stage` assinado por chamada de ferramenta em vez de por turno, ou permitir que o agente encadeie `consultar_cliente`→`consultar_contratos` sob o mesmo estágio; (b) fazer o `OutboxDispatcherService` respeitar o campo `retryable` do corpo de resposta e ter um limite de tentativas com dead-letter; (c) corrigir as 34 (6+6+22) suítes de teste quebradas antes do próximo merge.

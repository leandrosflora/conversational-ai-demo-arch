# Validação E2E do fix de bloqueio permanente do outbox (parked predecessor) — 2026-07-20

Contexto: a validação `2026-07-20-per-service-internal-auth-secrets-e2e.md` encontrou um bug real e bloqueante — um `channel.reply` estacionado como terminal-não-retryable (`status='failed'`, `next_attempt_at` ~10 anos no futuro) continuava sendo contado como predecessor "em andamento" pela ordenação de `journey_version` em `PostgresMessageInboxStore.ClaimBatchAsync`, travando para sempre todos os efeitos (memória, auditoria, Kafka) de qualquer turno seguinte na mesma conversa. O fix (branch `fix/outbox-parked-predecessor-blocking`, PR [conversation-orchestrator#6](https://github.com/leandrosflora/conversation-orchestrator/pull/6)) exclui predecessores estacionados terminalmente do bloqueio. Esta rodada valida o fix contra o ambiente Docker real, ponta a ponta, do webhook do `whatsapp-bff` até a resposta ao cliente.

**Achado de campo antes de validar**: o container `conversation-orchestrator` já estava rodando havia 4h com a imagem *sem* o fix e havia morrido com `Out of memory` ~2h antes desta validação — causa raiz: a mesma conversa presa em retry infinito do achado de 20/07, consumindo memória até o crash. Isso é evidência de impacto real do bug em ambiente local, não só teórico.

## Método

`docker compose up -d --build conversation-orchestrator` (reconstruído com o fix; dependências recriadas em cascata pelo compose). Dois turnos de uma conversa real enviados via webhook HMAC assinado (`X-Hub-Signature-256`, script Python ad-hoc) contra `whatsapp-bff`, número sintético novo (`17865557531`, não usado em rodadas anteriores), com `MOCK_AGENT_ENABLED=false` (OpenAI real):

1. "Quero renegociar minha divida" — sem CPF ainda.
2. "Meu CPF eh 12345678900" — CPF de teste conhecido.

## Jornada feliz — o que funcionou

| Etapa | Resultado |
|---|---|
| `GET /health/ready` nos 9 serviços de aplicação | **Confirmado** — todos `{"status":"ready","failures":[]}` |
| Webhook assinado (HMAC) → `whatsapp-bff` → Kafka → Orchestrator | **Confirmado** — `200 OK` nos dois turnos |
| Orchestrator → Agent Runtime (OpenAI real) | **Confirmado** — turno 1 e 2 processados, `intent=renegociar_divida` |
| Agent Runtime → `tool-service-renegotiation` (MCP) → `renegotiation-service` → `core-bancario-mock` | **Confirmado** — `consultar_cliente` e `consultar_contratos` retornaram `outcome=success` no turno 2; resposta do agente listou corretamente as 2 dívidas do cliente (Empréstimo Pessoal R$5.000, Cartão de Crédito R$1.800) |
| Orchestrator → `whatsapp-bff` → WhatsApp Cloud API real | **Confirmado o alcance** (`POST https://graph.facebook.com/v20.0/.../messages`); rejeitado pela Graph API real (`#131030 Recipient phone number not in allowed list`) — mesmo drift esperado das rodadas de 18/19/20-07, número sintético não cadastrado |
| **Fix validado**: efeitos do turno 2 não bloqueados pelo `channel.reply` estacionado do turno 1 | **Confirmado via Postgres** — ver tabela abaixo |
| Zero falhas de autenticação em qualquer um dos 9 serviços durante toda a rodada | **Confirmado** — nenhuma ocorrência de `401`/`403`/`unauthorized`/`unknown_caller` nos logs |
| Estabilidade do `conversation-orchestrator` pós-fix | **Confirmado** — container seguiu `Up` e saudável após os dois turnos, sem repetir o crash por OOM observado antes do fix |

### Estado do outbox (`ops.orchestrator_outbox`) para a conversa de teste

| journey_version | effect_type | status | attempt_count | next_attempt_at |
|---|---|---|---|---|
| 1 | audit.record, kafka.intent_detected, kafka.state_changed, memory.append_message ×2, memory.save_session | `published` | 1 | imediato |
| 1 | channel.reply | `failed` (estacionado) | 2 | ~10 anos no futuro |
| 2 | audit.record, kafka.intent_detected, memory.append_message ×2, memory.save_session | **`published`** | 1 | imediato |
| 2 | channel.reply | `failed` (estacionado) | 2 | ~10 anos no futuro |

Antes do fix, os 5 efeitos não-`channel.reply` do turno 2 teriam ficado presos em `status='pending', attempt_count=0`, sem nenhuma tentativa de dispatch, para sempre. Nesta rodada todos foram `published` normalmente — o `channel.reply` do turno 1 estacionado não bloqueou o turno 2.

## Não verificado nesta rodada

- Caminho de handoff completo (não exercitado nesta conversa).
- `journey_stage` da conversa permaneceu `IdentificationPending` após o CPF ser fornecido e os débitos identificados (log: `Rejected journey trigger RequestedRenegotiation from stage IdentificationPending`) — possível gap de máquina de estados não relacionado ao fix desta rodada; não investigado a fundo aqui, sinalizado para uma validação futura.
- Suítes pytest/dotnet test já confirmadas separadamente (`dotnet test` completo do `conversation-orchestrator`: 80/80, incluindo os 2 testes de regressão do fix); não re-executadas nesta rodada E2E.

## Conclusão

O fix de `fix/outbox-parked-predecessor-blocking` funciona corretamente no ambiente real: um `channel.reply` estacionado como terminal não bloqueia mais os efeitos de turnos seguintes da mesma conversa. A cadeia completa BFF → Kafka → Orchestrator → Agent Runtime (OpenAI real) → Tool Service (MCP) → Renegotiation Service → Core Bancário Mock → Orchestrator → outbox → whatsapp-bff → WhatsApp Cloud API real funciona ponta a ponta, com o único ponto de falha sendo o drift já conhecido e esperado (número de teste sintético não cadastrado na allow-list da Graph API). O container que antes morria por OOM devido a este bug permaneceu estável durante e após a rodada.

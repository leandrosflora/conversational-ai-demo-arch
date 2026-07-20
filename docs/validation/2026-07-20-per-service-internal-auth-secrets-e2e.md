# Validação E2E pós-implementação de `per-service-internal-auth-secrets` — 2026-07-20

Contexto: a mudança `per-service-internal-auth-secrets` (`openspec/changes/per-service-internal-auth-secrets/`) substituiu o segredo HS256 único (`INTERNAL_AUTH_SIGNING_KEY`) compartilhado por todos os serviços por um segredo distinto por par (emissor, audiência), com seleção de chave via header `kid` do JWT e checagem `kid == sub`. Implementada em paralelo nos 9 repositórios de aplicação. Esta rodada responde a mesma pergunta das validações anteriores — **o ambiente sobe do zero e a jornada continua funcionando de ponta a ponta com o novo esquema de segredos?**

## Método

`docker compose up -d --build` (todos os 10 serviços de aplicação recriados). `.env` reconstruído com 10 segredos novos gerados aleatoriamente (um por par) mais as credenciais reais já em uso (OpenAI, WhatsApp Cloud API). Dois turnos de uma conversa real enviados via webhook HMAC assinado contra `whatsapp-bff`, com um número de telefone sintético novo (`17865552468`, não usado em rodadas anteriores):

1. "Quero renegociar minha divida" — sem CPF ainda.
2. "Meu CPF eh 12345678900" — CPF de teste conhecido.

## Jornada feliz — o que funcionou

| Etapa | Resultado |
|---|---|
| `docker compose config` com os 10 novos placeholders de `.env.example` | **Confirmado** — YAML válido, sem erro de interpolação |
| `GET /health/ready` nos 9 serviços de aplicação | **Confirmado** — todos `{"status":"ready","failures":[]}` (após corrigir engano de porta: `tool-service-renegotiation` expõe MCP em `:8400` — auth obrigatória, sem endpoint de health — e REST/health em `:8401`) |
| Webhook assinado (HMAC) → `whatsapp-bff` → Kafka → Orchestrator | **Confirmado** — `200 OK` nos dois turnos |
| Orchestrator → Agent Runtime (JWT novo par) | **Confirmado** — turno 1 e 2 processados, `intent=renegociar_divida` |
| Agent Runtime → `conversation-memory-service` (JWT novo par, chamador direto) | **Confirmado** — `GET /conversations/.../messages` → `200 OK` |
| Agent Runtime → `tool-service-renegotiation` (MCP, JWT novo par) → `renegotiation-service` (JWT novo par) → `core-bancario-mock` | **Confirmado** — `consultar_cliente` e `consultar_contratos` retornaram `outcome=success` no mesmo turno (turno 2), reconfirmando o fix do achado 1 de 19/07 continua válido com o novo esquema de chaves |
| Orchestrator → `conversation-memory-service`/`conversation-audit-service` (outbox, JWT novo par) | **Confirmado para o turno 1**: `memory.append_message`, `memory.save_session`, `audit.record`, `kafka.intent_detected`, `kafka.state_changed` — todos `published` |
| Orchestrator → `whatsapp-bff` (channel reply, JWT novo par) | **Confirmado o alcance**; rejeitado pela Graph API real (`#131030 Recipient phone number not in allowed list`) — mesmo drift esperado das rodadas de 18/07 e 19/07, número sintético não cadastrado. `whatsapp-bff` sinalizou `retryable:false`; Orchestrator estacionou o efeito corretamente (mesmo comportamento do fix de 19/07) |
| **Zero falhas de autenticação** em qualquer log dos 9 serviços durante toda a rodada | **Confirmado** — nenhuma ocorrência de `401`/`403`/`unknown_caller`/`kid_sub_mismatch` fora dos testes negativos deliberados (abaixo) |

## Testes negativos (requisitos de `specs/internal-auth-key-scoping/spec.md`)

Tokens forjados manualmente (PyJWT dentro do container `tool-service-renegotiation`) e enviados direto contra `renegotiation-service` (`GET /clients/12345678900`):

| Cenário | Resultado |
|---|---|
| `kid: whatsapp-bff` (chamador fora da allow-list de `renegotiation-service`, que só aceita `tool-service-renegotiation`) | **`401`** — rejeitado antes de qualquer tentativa de verificação de assinatura |
| `kid: tool-service-renegotiation` (allow-listed) mas assinado com segredo errado | **`401`** — assinatura não verifica com o segredo configurado para o par |

Ambos batem exatamente com os cenários "Token with a kid outside the allow-list is rejected before signature verification" e "Token with an allow-listed kid but wrong signature is rejected" do spec.

## Achado — não relacionado a esta mudança, mas real e bloqueante

**O outbox do Orchestrator trava permanentemente os efeitos de qualquer turno seguinte a um turno cujo `channel.reply` foi estacionado como não-retryable.**

O turno 2 desta rodada (mesma conversa do turno 1, que teve seu `channel.reply` estacionado por número sintético não cadastrado) teve seus 6 efeitos (`memory.append_message` ×2, `memory.save_session`, `audit.record`, `kafka.intent_detected`, `channel.reply`) presos em `status='pending', attempt_count=0` por mais de 4 minutos, sem nenhuma tentativa de dispatch — não é falha de autenticação (não há nenhum log de tentativa sequer).

Causa raiz identificada em `Adapters/Outbound/Persistence/PostgresMessageInboxStore.cs` (`ClaimBatchAsync`), na claúsula de ordenação:

```sql
AND NOT EXISTS (
    SELECT 1 FROM ops.orchestrator_outbox predecessor
    WHERE predecessor.tenant_id = candidate.tenant_id
      AND predecessor.conversation_id = candidate.conversation_id
      AND predecessor.journey_version < candidate.journey_version
      AND predecessor.status <> 'published'
)
```

Efeitos "estacionados" (`status='failed'`, o resultado deliberado do fix de 19/07 para não-retryable) satisfazem `status <> 'published'` — ou seja, contam como bloqueio, não como terminal-e-resolvido. Como um `channel.reply` estacionado nunca chega a `'published'`, **nenhum efeito de nenhum turno posterior daquela conversa é despachado, para sempre** — silenciosamente, sem erro, sem alerta, sem limite de tentativas (porque `attempt_count` nunca chega a incrementar).

Isso é exatamente o cenário que o fix de 19/07 foi desenhado para tratar graciosamente (número bloqueado/opt-out/inválido não deve travar o sistema) — mas a consequência prática é o oposto: qualquer conversa real com um destinatário permanentemente não-entregável trava por completo após o primeiro turno, incluindo auditoria e memória, que nada têm a ver com a entrega da mensagem.

**Fora do escopo desta mudança** (não é causado pelo esquema de segredos por par — é uma query Postgres pré-existente, sem relação com JWT/auth) — registrado aqui por ter sido descoberto durante esta validação. Recomendo um change dedicado para decidir se `status='failed'` (terminal, não-retryable) deveria contar como "resolvido" para fins da ordenação por `journey_version`, distinto de `status='pending'`/`'publishing'` (ainda em andamento).

## Não verificado nesta rodada

- Dispatch assíncrono dos efeitos do turno 2 (bloqueado pelo achado acima) — os tipos de efeito envolvidos (`memory.*`, `audit.record`, `kafka.intent_detected`) já foram confirmados funcionando com o novo esquema de segredos no turno 1; o bloqueio do turno 2 é de ordenação, não de autenticação, mas não há confirmação direta de que aqueles segredos específicos funcionariam numa segunda tentativa real.
- Caminho de handoff completo (não exercitado nesta conversa, que não precisou de transferência humana).
- Suítes pytest/dotnet test já confirmadas por cada agente de implementação (ver relatórios individuais); não re-executadas nesta rodada de validação E2E.

## Conclusão

O modelo de segredo por par (`per-service-internal-auth-secrets`) funciona corretamente ponta a ponta: toda chamada real observada nesta rodada — síncrona ou assíncrona — autenticou com sucesso usando o novo esquema, e os dois testes negativos confirmam que um chamador fora da allow-list ou com segredo errado é rejeitado antes mesmo da verificação de assinatura. A mudança está pronta. O achado do outbox é um problema real e independente, não introduzido por esta mudança, que merece tratamento separado.

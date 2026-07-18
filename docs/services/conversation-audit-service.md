# conversation-audit-service

Repo: [`leandrosflora/conversation-audit-service`](https://github.com/leandrosflora/conversation-audit-service) · Stack: .NET 8, Minimal API, Npgsql · Porta local/host: `8300`

## Responsabilidade principal

Audit Service real da plataforma: recebe um evento de jornada por mensagem processada e grava uma linha durável em PostgreSQL. Substitui o `audit-service-mock` (removido) e já é chamado de verdade pelo `conversation-orchestrator` ao final de todo `IngestMessageUseCase.ExecuteAsync`.

## Dados que o serviço possui

Nenhum modelo de domínio próprio além do DTO de entrada (`JourneyAuditEvent`: `ConversationId`, `Intent?`, `Outcome`, `Timestamp`) — todo o estado persistido vive na tabela genérica `ops.audit_events`, já provisionada para servir qualquer tipo de evento de auditoria da plataforma, não só jornadas de conversa.

## APIs publicadas

| Método | Rota | Descrição |
|---|---|---|
| `POST` | `/journey-events` | Recebe `{ conversationId, intent?, outcome, timestamp }` e grava uma linha em `ops.audit_events` antes de responder |

Validação: `400 Bad Request` se `conversationId`, `outcome` ou `timestamp` estiverem ausentes. Sucesso: `202 Accepted` (sem corpo) só depois que a escrita no Postgres é confirmada. `503 Service Unavailable` se o PostgreSQL estiver inacessível — nunca um hang ou um `500` cru.

## Eventos publicados

Nenhum. Não usa Kafka.

## Eventos consumidos

Nenhum.

## Dependências síncronas

Nenhuma chamada HTTP a outro serviço — a única dependência é o PostgreSQL (ver Persistência).

## Persistência & infraestrutura

- **PostgreSQL** (`ops.audit_events`) — único armazenamento do serviço, via `Npgsql` direto (sem ORM). `NpgsqlDataSource` é um singleton com `Timeout=5s`/`CommandTimeout=5s` forçados na connection string, para que uma indisponibilidade real do Postgres vire `503` rápido em vez dos defaults bem mais longos do Npgsql (15s conexão / 30s comando).
- Mapeamento fixo de campos (`ops.audit_events` é uma tabela de auditoria genérica, não específica de jornada de conversa):
  - `tenant_id` = tenant seed `demo-bank` (`00000000-0000-0000-0000-000000000001`) — o mesmo tenant fixo usado em todo o workspace, já que não existe multi-tenancy real aqui.
  - `actor_type` = `"system"`, `actor_id` = `"conversation-orchestrator"`, `action` = `"conversation.journey_processed"`, `resource_type` = `"conversation"`.
  - `resource_id` = o `conversationId` recebido.
  - `payload` (jsonb) = `{"intent": ..., "outcome": ...}` — `intent` pode ser `null`.
  - `created_at` = o `timestamp` recebido no request (não `now()` do servidor) — reflete quando o Orchestrator observou o desfecho, não quando esta chamada HTTP chegou.

## Regras de negócio

1. Não há chave de deduplicação: um retry de rede do lado do Orchestrator (`AddStandardResilienceHandler`, até 2 tentativas) pode gerar duas linhas para o mesmo evento. Aceito para uma trilha de auditoria (naturalmente aditiva) — revisar só se isso virar um problema real de relatório.
2. `created_at` é sempre o timestamp que o chamador informou, nunca recalculado pelo servidor — preserva quando o evento realmente aconteceu do lado do Orchestrator.
3. Indisponibilidade do Postgres nunca vira um `500` genérico nem trava a requisição — sempre `503`, dentro do timeout configurado (5s).

## Referências de arquitetura

- [ADR 0002 — Hexagonal / ports-and-adapters nos serviços .NET](../adr/0002-hexagonal-ports-and-adapters.md)
- [ADR 0004 — Resiliência catch-log-continue](../adr/0004-catch-log-continue-resilience.md)
- [conversation-orchestrator](conversation-orchestrator.md) — quem chama este serviço
- [Contratos — Datastores](../contracts/data-stores.md)

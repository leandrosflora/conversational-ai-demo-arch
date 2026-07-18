# conversation-handoff-service

Repo: [`leandrosflora/conversation-handoff-service`](https://github.com/leandrosflora/conversation-handoff-service) · Stack: .NET 8, Minimal API, Npgsql · Porta local/host: `8200`

## Responsabilidade principal

Handoff Service real da plataforma: recebe um pedido de transferência para atendimento humano e grava uma linha durável em PostgreSQL. Diferente do Audit Service, a chamada do `conversation-orchestrator` para cá **nunca esteve comentada** — sempre que o Agent Runtime recomenda ou requer handoff (`RequiresHandoff=true`), o Orchestrator já chamava esse host incondicionalmente; só faltava um serviço real do outro lado.

## Dados que o serviço possui

Nenhum modelo de domínio próprio além do DTO de entrada (`HandoffRequestRecord`: `ConversationId`, `Reason`) — todo o estado persistido vive na tabela `conversation.handoffs`, já provisionada no schema `conversation`.

## APIs publicadas

| Método | Rota | Descrição |
|---|---|---|
| `POST` | `/handoffs` | Recebe `{ conversationId, reason }` e grava uma linha em `conversation.handoffs` antes de responder |

Validação: `400 Bad Request` se `conversationId` ou `reason` estiverem ausentes. Sucesso: `202 Accepted` (sem corpo) só depois que a escrita no Postgres é confirmada. `503 Service Unavailable` se o PostgreSQL estiver inacessível — nunca um hang ou um `500` cru.

## Eventos publicados

Nenhum. Não usa Kafka.

## Eventos consumidos

Nenhum.

## Dependências síncronas

Nenhuma chamada HTTP a outro serviço — a única dependência é o PostgreSQL (ver Persistência). Não há uma etapa real de "transferir para um atendente humano" (o relacionamento `handoffService → attendance` do modelo C4 é conceitual): este serviço aceita e persiste o pedido, o mesmo limite de escopo já adotado pelo `conversation-audit-service` em relação ao Data Lake.

## Persistência & infraestrutura

- **PostgreSQL** (`conversation.handoffs`) — único armazenamento do serviço, via `Npgsql` direto (sem ORM), mesmo padrão do `conversation-audit-service` (`NpgsqlDataSource` singleton, `Timeout=5s`/`CommandTimeout=5s` forçados).
- **A FK de `conversation.handoffs.conversation_id`** exige uma linha existente em `conversation.conversations` — tabela que nenhum serviço deste workspace popula de verdade (não existe resolução de telefone → UUID de conversa em lugar nenhum). Toda linha usa a conversa seed já provisionada (`70000000-0000-0000-0000-000000000001`, tenant `demo-bank`) como FK fixa; o ID real da conversa (o telefone) vai em `metadata.externalConversationId`, para não se perder.
- `target_queue` é sempre o literal `"human-support"` — não existe conceito de fila/roteamento por skill neste workspace ainda.
- `status` fica no valor default da tabela (`"pending"`) — não há fluxo de aceitar/fechar um handoff implementado (as colunas `accepted_at`/`closed_at` existem no schema, mas nada os escreve).

## Regras de negócio

1. Toda linha de handoff aponta para a mesma conversa seed — duas conversas reais diferentes só se distinguem por `metadata.externalConversationId`, nunca por `conversation_id`. Aceitável porque nenhuma ferramenta de operador consulta `conversation.handoffs` ainda.
2. Não há chave de deduplicação: um retry de rede do lado do Orchestrator pode gerar duas linhas para o mesmo pedido de handoff — mesmo trade-off já aceito no Audit Service.
3. Indisponibilidade do Postgres nunca vira um `500` genérico nem trava a requisição — sempre `503`, dentro do timeout configurado (5s).

## Referências de arquitetura

- [ADR 0002 — Hexagonal / ports-and-adapters nos serviços .NET](../adr/0002-hexagonal-ports-and-adapters.md)
- [ADR 0004 — Resiliência catch-log-continue](../adr/0004-catch-log-continue-resilience.md)
- [conversation-orchestrator](conversation-orchestrator.md) — quem chama este serviço
- [Contratos — Datastores](../contracts/data-stores.md)

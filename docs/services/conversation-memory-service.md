# conversation-memory-service

Repo: [`leandrosflora/conversation-memory-service`](https://github.com/leandrosflora/conversation-memory-service) · Stack: Python, FastAPI, Redis, MongoDB · Porta local: `8600`

## Responsabilidade principal

Memória da plataforma: sessão de conversa ativa (Redis, com TTL) e memória durável (MongoDB) — histórico de mensagens e fatos de memória de longo prazo por usuário. Já é consumido de verdade pelo `conversation-orchestrator` (sessão e histórico); nenhum outro serviço o chama ainda.

## Dados que o serviço possui

- **Sessão ativa** (Redis, chave `session:{conversation_id}`): payload JSON opaco (`data`, definido inteiramente por quem chama) + `updated_at`, com TTL (default `session_ttl_seconds=1800`, o mesmo TTL que o Orchestrator já usava para sua sessão em memória antes desta integração).
- **Histórico de mensagens** (MongoDB `conversation_messages`): `tenantId`, `conversationId`, `userId`, `channel`, `provider`, `externalMessageId`, `role`, `content`, `metadata`, `correlationId`, `traceId`, `createdAt`.
- **Memória de longo prazo** (MongoDB `agent_memory`): um documento por `(tenantId, userId, memoryType)`, com `facts[]`, `sourceConversationId`, `createdAt`/`updatedAt`, `expiresAt` opcional.

## APIs publicadas

| Método | Rota | Descrição |
|---|---|---|
| `GET` | `/sessions/{conversation_id}` | Sessão ativa; `404` se não existir ou tiver expirado (TTL) |
| `PUT` | `/sessions/{conversation_id}` | Cria ou substitui a sessão; TTL default ou `ttl_seconds` explícito no corpo |
| `DELETE` | `/sessions/{conversation_id}` | Remove a sessão; `204` mesmo se já não existir (idempotente) |
| `POST` | `/conversations/{conversation_id}/messages` | Anexa uma mensagem ao histórico; `201` se criada, `200` se já existia (idempotente, ver Regras de negócio) |
| `GET` | `/conversations/{conversation_id}/messages` | Lista o histórico, filtrado por `tenant_id`, com `limit` opcional (mais recentes, em ordem cronológica) |
| `GET` | `/users/{user_id}/memory` | Fatos de memória para `tenant_id`/`memory_type`; lista vazia se não houver nada (não é erro) |
| `PUT` | `/users/{user_id}/memory` | Substitui o array `facts[]` inteiro (upsert); `ttl_seconds` opcional recalcula `expiresAt` |

Qualquer endpoint responde `503 Service Unavailable` quando Redis ou MongoDB estão inacessíveis (`DatastoreUnavailableError`, mapeada por um exception handler central em `app/main.py`) — nunca um hang ou um `500` cru.

## Eventos publicados

Nenhum.

## Eventos consumidos

Nenhum.

## Dependências síncronas

| Destino | Comportamento se indisponível |
|---|---|
| Redis (`:6379`) | Client com `socket_connect_timeout=3s`/`socket_timeout=3s` — sem isso, o timeout bem mais longo do `redis-py` deixaria a chamada pendurada antes do `503` disparar |
| MongoDB (`:27017` interno / `:27018` host) | Erros do driver (`PyMongoError`) viram `DatastoreUnavailableError` → `503` em toda operação de sessão/histórico/memória |

## Persistência & infraestrutura

- **Redis**: sessão ativa por conversa, com TTL — é a única fonte de verdade para o estado "quente" da conversa.
- **MongoDB**: histórico de mensagens (`conversation_messages`) e memória de longo prazo (`agent_memory`), usando o schema/índices já provisionados em `database/conversational-ai-mongodb-init.js` e o usuário de app de privilégio mínimo (`conversational_ai_app`, `readWrite`) — nunca o usuário root.
- No startup, `ensure_indexes` cria (de forma idempotente) os índices já definidos no script de init do Mongo — cobre o caso de um volume Mongo pré-existente que nunca rodou aquele script.

## Regras de negócio

1. **Histórico é idempotente por `externalMessageId`**: se já existe um documento com o mesmo `(tenantId, externalMessageId)`, o append é tratado como um retry — devolve o documento existente com `200 OK` em vez de duplicar ou dar erro de chave única. Uma corrida entre dois appends concorrentes com o mesmo `externalMessageId` é resolvida pegando o documento que "ganhou" após um `DuplicateKeyError`.
2. **Memória de longo prazo é substituição total, não merge**: `PUT /users/{id}/memory` substitui o array `facts[]` inteiro daquele `(tenantId, userId, memoryType)` — não faz merge fato a fato. É lossy se dois chamadores concorrentes atualizarem fatos diferentes do mesmo usuário ao mesmo tempo; aceitável porque há só um chamador esperado (Agent Runtime) e nenhum ainda chama este endpoint de verdade.
3. **Expiração de memória é avaliada na leitura, não só pelo índice TTL do Mongo**: o índice TTL do Mongo varre e apaga periodicamente, não instantaneamente — um documento pode estar logicamente expirado antes de ser fisicamente apagado. `GET /users/{id}/memory` trata `expiresAt` no passado como ausente, independentemente de o documento ainda existir fisicamente.
4. A sessão (`data`) é um payload JSON opaco — o serviço não impõe nenhum schema sobre o conteúdo, já que quem chama (`conversation-orchestrator`) define sozinho o que guarda ali.

## Referências de arquitetura

- [ADR 0002 — Hexagonal / ports-and-adapters nos serviços .NET](../adr/0002-hexagonal-ports-and-adapters.md) — este serviço é Python, mas o `conversation-orchestrator` que o consome segue essa convenção do lado cliente (`IConversationMemoryClient`).
- [Diagramas de sequência da jornada](../architecture/sequence-diagrams.md)
- [Contratos — Datastores](../contracts/data-stores.md)

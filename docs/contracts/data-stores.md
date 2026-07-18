# Datastores

**Fonte de verdade:** varredura do código-fonte em 2026-07-17 (ver [`services-map.md`](services-map.md)).

## O que está provisionado vs. o que é realmente usado

`docker-compose.yml` (neste repositório) sobe PostgreSQL, MongoDB, Redis, Kafka e OpenSearch como infraestrutura local. **Kafka, PostgreSQL, MongoDB, Redis e OpenSearch são efetivamente lidos/escritos por serviços implementados hoje** — MongoDB e Redis desde que `conversation-memory-service` foi construído, OpenSearch desde que `knowledge-service` foi construído, e PostgreSQL desde que `conversation-audit-service` (`ops.audit_events`) e `conversation-handoff-service` (`conversation.handoffs`) foram construídos — ambas as tabelas já provisionadas em `database/conversational-ai-postgres-init.sql`.

| Datastore | Provisionado em `docker-compose.yml`? | Usado por algum serviço hoje? |
|---|---|---|
| Kafka | Sim | **Sim** — whatsapp-bff, conversation-orchestrator, agent-runtime-renegotiation, tool-service-renegotiation |
| PostgreSQL | Sim | **Sim** — conversation-audit-service (`ops.audit_events`), conversation-handoff-service (`conversation.handoffs`) |
| MongoDB | Sim | **Sim** — conversation-memory-service (`conversation_messages`, `agent_memory`) |
| Redis | Sim | **Sim** — conversation-memory-service (sessão ativa) |
| OpenSearch | Sim | **Sim** — knowledge-service (`faq_chunks`, busca vetorial k-NN) |

## Por serviço

| Serviço | Datastore usado | Detalhe |
|---|---|---|
| whatsapp-bff | Kafka | Produtor e consumidor de `channel.webhook.received`; produtor de `channel.message.received`/`channel.message.status` |
| conversation-orchestrator | Kafka (produtor) | `intent.detected`/`conversation.state_changed`; já chama `conversation-memory-service` (sessão/histórico), `conversation-audit-service` (evento de jornada) e `conversation-handoff-service` (pedido de handoff) via HTTP — não persiste nada diretamente |
| agent-runtime-renegotiation | Kafka (produtor) | `agent.events` — já chama `knowledge-service` via `GET /search` (`app/tools/knowledge.py`) |
| tool-service-renegotiation | Kafka (produtor) | `tool.executed` |
| conversation-memory-service | Redis; MongoDB | Redis: sessão ativa por conversa, com TTL (`GET`/`PUT`/`DELETE /sessions/{conversation_id}`). MongoDB: histórico de mensagens em `conversation_messages` (`/conversations/{id}/messages`) e fatos de memória de longo prazo em `agent_memory` (`/users/{id}/memory`) |
| knowledge-service | OpenSearch | Índice `faq_chunks` (k-NN vector search sobre embeddings OpenAI). Ingestão de PDFs de FAQ de renegociação em `knowledge-service/data/faq_pdfs/`, no startup e via `POST /admin/reindex` |
| conversation-audit-service | PostgreSQL | `POST /journey-events` grava uma linha em `ops.audit_events` por evento (tenant seed `demo-bank`, `actor_type='system'`, `action='conversation.journey_processed'`) |
| conversation-handoff-service | PostgreSQL | `POST /handoffs` grava uma linha em `conversation.handoffs` por pedido (conversa seed fixa, `target_queue='human-support'`, `reason` repassado, `metadata.externalConversationId` com o ID real da conversa) |
| renegotiation-service | Nenhum | Stateless — toda informação vem de chamadas HTTP síncronas ao Core Bancário mock |
| core-bancario-mock | Nenhum | Dados fake gerados inline a cada chamada |

## Por que isso importa

PostgreSQL, MongoDB, Redis e OpenSearch já deixaram a categoria "só provisionado, sem consumidor real": `conversation-audit-service`, `conversation-handoff-service`, `conversation-memory-service` e `knowledge-service` são seus primeiros consumidores reais, e todos já **são chamados de verdade** pelos respectivos clients (`conversation-orchestrator` → `conversation-memory-service`/`conversation-audit-service`/`conversation-handoff-service`; `agent-runtime-renegotiation` → `knowledge-service`). Uma leitura deste documento que assuma "a plataforma já usa Postgres para gravar auditoria ou handoffs", "Mongo/Redis para memória de conversa" ou "OpenSearch para busca de FAQ" agora está correta.

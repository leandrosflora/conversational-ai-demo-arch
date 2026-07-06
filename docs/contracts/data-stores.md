# Datastores

**Fonte de verdade:** varredura do código-fonte em 2026-07-06 (ver [`services-map.md`](services-map.md)).

## O que está provisionado vs. o que é realmente usado

`docker-compose.yml` (neste repositório) sobe PostgreSQL, MongoDB, Redis e Kafka como infraestrutura local. **Apenas o Kafka é efetivamente lido/escrito por algum serviço implementado hoje.** PostgreSQL, MongoDB e Redis estão provisionados — com schemas já preparados (`database/conversational-ai-postgres-init.sql`, `database/conversational-ai-mongodb-init.js`) — mas nenhum código de aplicação neste workspace se conecta a eles.

| Datastore | Provisionado em `docker-compose.yml`? | Usado por algum serviço hoje? |
|---|---|---|
| Kafka | Sim | **Sim** — whatsapp-bff, conversation-orchestrator, agent-runtime-renegotiation, tool-service-renegotiation |
| PostgreSQL | Sim | Não |
| MongoDB | Sim | Não |
| Redis | Sim | Não |

## Por serviço

| Serviço | Datastore usado | Detalhe |
|---|---|---|
| whatsapp-bff | Kafka | Produtor e consumidor de `channel.webhook.received`; produtor de `channel.message.received`/`channel.message.status` |
| conversation-orchestrator | Kafka (produtor); memória | `intent.detected`/`conversation.state_changed`; sessão de conversa em `ConcurrentDictionary` (TTL 30 min, perdida em restart) |
| agent-runtime-renegotiation | Kafka (produtor) | `agent.events` |
| tool-service-renegotiation | Kafka (produtor) | `tool.executed` |
| renegotiation-service | Nenhum | Stateless — toda informação vem de chamadas HTTP síncronas ao Core Bancário mock |
| core-bancario-mock | Nenhum | Dados fake gerados inline a cada chamada |

## Por que isso importa

PostgreSQL, MongoDB e Redis existem no `docker-compose.yml` porque servem os componentes ainda **não implementados** (Memory Service, Knowledge Service, Audit Service, Handoff Service — ver [`docs/runbook.md` §7](../runbook.md)) — os schemas já foram desenhados para quando esses serviços forem construídos. Até lá, qualquer leitura deste documento que assuma que "a plataforma já usa Postgres para X" está incorreta: a plataforma, hoje, só persiste estado de fato via Kafka (como trilha de eventos) e memória de processo (efêmera).

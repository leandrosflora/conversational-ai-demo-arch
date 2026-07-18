# Mapa de serviços

**Fonte de verdade:** varredura do código-fonte de cada repositório, feita em 2026-07-06, revisada contra uma execução real da jornada E2E em 2026-07-13 (ver [relatório de validação](../validation/2026-07-13-e2e-journey.md)), complementada em 2026-07-17 com os serviços de conhecimento e memória conversacional já implementados, e em 2026-07-18 com o Audit Service real (`conversation-audit-service`) e sua integração no Orchestrator. Este documento — junto com [`kafka-events.md`](kafka-events.md) e [`data-stores.md`](data-stores.md) — é a referência canônica de portas/tópicos/serviços; `docs/runbook.md` aponta para cá em vez de manter uma segunda cópia.

## Serviços implementados

| Serviço | Repo | Tipo | Entrada principal | Saída principal | Observação de implementação |
|---|---|---|---|---|---|
| whatsapp-bff | [leandrosflora/whatsapp-bff](https://github.com/leandrosflora/whatsapp-bff) | Channel BFF | Webhook WhatsApp (`POST /webhooks/whatsapp`) | `POST /messages` no Orchestrator; resposta via WhatsApp Cloud API | .NET 8; Kafka como fila durável de entrada (`channel.webhook.received`) |
| conversation-orchestrator | [leandrosflora/conversation-orchestrator](https://github.com/leandrosflora/conversation-orchestrator) | Orquestração/jornada | `POST /messages` | `POST /process` no Agent Runtime; eventos `intent.detected`/`conversation.state_changed`; `POST /journey-events` no Audit Service | .NET 8; sessão/histórico via `conversation-memory-service`; auditoria via `conversation-audit-service` |
| agent-runtime-renegotiation | [leandrosflora/agent-runtime-renegotiation](https://github.com/leandrosflora/agent-runtime-renegotiation) | Agente de IA | `POST /process` | Tools MCP no Tool Service; busca no Knowledge Service; evento `agent.events` | Python/FastAPI/Strands+OpenAI; threshold de confiança 0.6 |
| tool-service-renegotiation | [leandrosflora/tool-service-renegotiation](https://github.com/leandrosflora/tool-service-renegotiation) | MCP tool server | Chamadas MCP (7 tools) | HTTP no Renegotiation Service; evento `tool.executed` | Python/FastMCP; nunca publica argumentos de tool no Kafka |
| renegotiation-service | [leandrosflora/renegotiation-service](https://github.com/leandrosflora/renegotiation-service) | Gateway/BFF de domínio | 7 endpoints REST | HTTP nas 4 APIs do Core Bancário mock | .NET 8; sem Kafka; pass-through, sem regra de crédito própria |
| core-bancario-mock | *(sem repo próprio — pasta local)* | Mock de sistema externo | 7 endpoints REST (4 APIs em 4 portas) | — | .NET 8, processo único, sem persistência |
| knowledge-service | [leandrosflora/knowledge-service](https://github.com/leandrosflora/knowledge-service) | RAG / busca de conhecimento | `GET /search`; `POST /admin/reindex` | OpenSearch (`faq_chunks`) e OpenAI Embeddings; resultados para o Agent Runtime | Python/FastAPI; porta `8500`; ingere PDFs de FAQ e executa busca vetorial k-NN; já é consumido pelo Agent Runtime |
| conversation-memory-service | [leandrosflora/conversation-memory-service](https://github.com/leandrosflora/conversation-memory-service) | Memória conversacional | Sessões (`GET`/`PUT`/`DELETE /sessions/{conversation_id}`), histórico e memória de usuário | Redis para sessão com TTL; MongoDB para `conversation_messages` e `agent_memory` | Python/FastAPI; porta `8600`; já é consumido pelo Orchestrator (sessão e histórico) |
| conversation-audit-service | [leandrosflora/conversation-audit-service](https://github.com/leandrosflora/conversation-audit-service) | Audit Service | `POST /journey-events` | PostgreSQL (`ops.audit_events`) | .NET 8; porta `8300`; já é consumido pelo Orchestrator ao fim de cada mensagem processada |

## Dependências assumidas (não implementadas neste workspace)

| Nome | Porta assumida | Chamado por | Situação |
|---|---|---|---|
| Handoff Service | `:8200` | conversation-orchestrator (`POST /handoffs`) | Cliente HTTP existe; falha é só logada, nunca bloqueia |
| Salesforce CRM / Data Lake Corporativo | — | Nenhum código do workspace | Existem apenas nos documentos de negócio/C4 (ver [`business-context.md`](../context/business-context.md)) |

## Detalhe da varredura

Cada linha da tabela acima foi confirmada lendo o código-fonte de cada repositório (`Program.cs`/`app/main.py`, `Adapters/`/`app/`, `Configuration/`/`app/config.py`, `appsettings.json`/`requirements.txt`) em 2026-07-06 — não a partir de specs ou documentação anterior. Os serviços `knowledge-service` e `conversation-memory-service` foram acrescentados em 2026-07-17; `conversation-audit-service` foi acrescentado em 2026-07-18, junto com a confirmação de que `conversation-orchestrator` já o chama de verdade (`IngestMessageUseCase.cs`, chamada antes comentada). Ver as páginas individuais em [`docs/services/`](../services/) para o detalhe completo de cada serviço, e [`kafka-events.md`](kafka-events.md) para a matriz de eventos.

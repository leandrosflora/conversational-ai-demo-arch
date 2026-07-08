# Mapa de serviços

**Fonte de verdade:** varredura do código-fonte de cada repositório, feita em 2026-07-06. Este documento — junto com [`kafka-events.md`](kafka-events.md) e [`data-stores.md`](data-stores.md) — é a referência canônica de portas/tópicos/serviços; `docs/runbook.md` aponta para cá em vez de manter uma segunda cópia.

## Serviços implementados

| Serviço | Repo | Tipo | Entrada principal | Saída principal | Observação de implementação |
|---|---|---|---|---|---|
| whatsapp-bff | [leandrosflora/whatsapp-bff](https://github.com/leandrosflora/whatsapp-bff) | Channel BFF | Webhook WhatsApp (`POST /webhooks/whatsapp`) | `POST /messages` no Orchestrator; resposta via WhatsApp Cloud API | .NET 8; Kafka como fila durável de entrada (`channel.webhook.received`) |
| conversation-orchestrator | [leandrosflora/conversation-orchestrator](https://github.com/leandrosflora/conversation-orchestrator) | Orquestração/jornada | `POST /messages` | `POST /process` no Agent Runtime; eventos `intent.detected`/`conversation.state_changed` | .NET 8; sessão em memória (TTL 30 min) |
| agent-runtime-renegotiation | [leandrosflora/agent-runtime-renegotiation](https://github.com/leandrosflora/agent-runtime-renegotiation) | Agente de IA | `POST /process` | Tools MCP no Tool Service; evento `agent.events` | Python/FastAPI/Strands+OpenAI; threshold de confiança 0.6 |
| tool-service-renegotiation | [leandrosflora/tool-service-renegotiation](https://github.com/leandrosflora/tool-service-renegotiation) | MCP tool server | Chamadas MCP (7 tools) | HTTP no Renegotiation Service; evento `tool.executed` | Python/FastMCP; nunca publica argumentos de tool no Kafka |
| renegotiation-service | [leandrosflora/renegotiation-service](https://github.com/leandrosflora/renegotiation-service) | Gateway/BFF de domínio | 7 endpoints REST | HTTP nas 4 APIs do Core Bancário mock | .NET 8; sem Kafka; pass-through, sem regra de crédito própria |
| core-bancario-mock | *(sem repo próprio — pasta local)* | Mock de sistema externo | 7 endpoints REST (4 APIs em 4 portas) | — | .NET 8, processo único, sem persistência |

## Dependências assumidas (não implementadas neste workspace)

| Nome | Porta assumida | Chamado por | Situação |
|---|---|---|---|
| Handoff Service | `:8200` | conversation-orchestrator (`POST /handoffs`) | Cliente HTTP existe; falha é só logada, nunca bloqueia |
| Audit Service | `:8300` | conversation-orchestrator (`POST /journey-events`) | Idem |
| Knowledge Service | `:8500` | agent-runtime-renegotiation (`GET /search`) | Idem — retorna mensagem de indisponibilidade ao agente |
| Salesforce CRM / Data Lake Corporativo | — | Nenhum código do workspace | Existem apenas nos documentos de negócio/C4 (ver [`business-context.md`](../context/business-context.md)) |

## Detalhe da varredura

Cada linha da tabela acima foi confirmada lendo o código-fonte de cada repositório (`Program.cs`/`app/main.py`, `Adapters/`/`app/`, `Configuration/`/`app/config.py`, `appsettings.json`/`requirements.txt`) em 2026-07-06 — não a partir de specs ou documentação anterior. Ver as páginas individuais em [`docs/services/`](../services/) para o detalhe completo de cada serviço, e [`kafka-events.md`](kafka-events.md) para a matriz de eventos.

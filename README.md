# conversational-ai-demo-arch

[![Documentation](https://img.shields.io/badge/docs-MkDocs-526CFE?logo=materialformkdocs&logoColor=white)](https://leandrosflora.github.io/conversational-ai-demo-arch/)
[![Publish MkDocs](https://github.com/leandrosflora/conversational-ai-demo-arch/actions/workflows/docs.yml/badge.svg)](https://github.com/leandrosflora/conversational-ai-demo-arch/actions/workflows/docs.yml)

**Documentação publicada:** https://leandrosflora.github.io/conversational-ai-demo-arch/

Arquitetura de referência para plataformas de IA conversacional utilizando agentes, MCP, RAG, WhatsApp, APIs corporativas e observabilidade ponta a ponta.

## Documentação

- [Contexto de negócio](docs/context/business-context.md) — jornadas, personas e escopo.
- [C4 nível 1 (contexto)](docs/architecture/c4-context.md) e [diagramas C4](docs/architecture/C4/) (`.puml`/`.svg`/`.png`).
- [Diagramas de sequência da jornada](docs/architecture/sequence-diagrams.md) — passo a passo técnico, do webhook do WhatsApp até a consulta de débitos/elegibilidade.
- [Páginas de referência por serviço](docs/services/) — responsabilidade, APIs, eventos e regras de negócio de cada um dos 10 serviços implementados.
- [Contratos](docs/contracts/) — mapa de serviços, matriz de eventos Kafka, datastores.
- [ADRs](docs/adr/) — decisões de arquitetura já implementadas no código.
- [Arquitetura de segurança](docs/security/security-architecture.md).
- [Runbook do ambiente local](docs/runbook.md) — como subir a infraestrutura e os serviços de aplicação.
- [Validações E2E](docs/validation/) — execuções reais da jornada completa contra os serviços rodando, comparando comportamento observado com o que os docs afirmam.

## Ambiente local

Subir infraestrutura local:

```bash
docker compose up -d
```

Parar e remover containers:

```bash
docker compose down
```

Remover containers e volumes:

```bash
docker compose down -v
```

### Serviços

| Serviço | URL/porta local | Credenciais |
| --- | --- | --- |
| Redis | `localhost:6379` | - |
| MongoDB | `localhost:27018` | `admin/admin` |
| PostgreSQL | `localhost:5432` | `postgres/postgres` |
| Kafka | `localhost:29092` | - |
| OpenSearch | `localhost:9200` | - |
| Jaeger UI | `localhost:16686` | - |
| Loki | `localhost:3100` | - |
| Prometheus | `localhost:9090` | - |
| Grafana | `localhost:3001` | `admin/admin` |

### Observabilidade

O Grafana já sobe provisionado com datasources para:

- Prometheus
- Loki
- Jaeger

O Prometheus coleta métricas dele mesmo, do Jaeger e de uma aplicação exposta no host em `localhost:8080/metrics`. Os serviços de aplicação hoje propagam `TraceId`/`SpanId`/`CorrelationId` nos logs (ver [`docs/services/`](docs/services/)), mas nenhum publica métricas OpenTelemetry próprias ainda — a stack está pronta para quando isso for instrumentado.

## Repositórios envolvidos

| Serviço | Repositório |
|---|---|
| Channel BFF | [whatsapp-bff](https://github.com/leandrosflora/whatsapp-bff) |
| Conversation Orchestrator | [conversation-orchestrator](https://github.com/leandrosflora/conversation-orchestrator) |
| Agent Runtime | [agent-runtime-renegotiation](https://github.com/leandrosflora/agent-runtime-renegotiation) |
| Tool Service (MCP) | [tool-service-renegotiation](https://github.com/leandrosflora/tool-service-renegotiation) |
| Renegotiation Service | [renegotiation-service](https://github.com/leandrosflora/renegotiation-service) |
| Core Bancário (mock) | sem repositório próprio — pasta local `core-bancario-mock/` |
| Knowledge Service | [knowledge-service](https://github.com/leandrosflora/knowledge-service) |
| Conversation Memory Service | [conversation-memory-service](https://github.com/leandrosflora/conversation-memory-service) |
| Conversation Audit Service | [conversation-audit-service](https://github.com/leandrosflora/conversation-audit-service) |
| Conversation Handoff Service | [conversation-handoff-service](https://github.com/leandrosflora/conversation-handoff-service) |

Detalhe de responsabilidades, APIs e regras de negócio de cada um em [`docs/services/`](docs/services/).

Os 10 repos (esses 9 + este) têm CI (`.github/workflows/ci.yml`) rodando build/teste (ou, neste repo, `docker compose config`) a cada push/PR para o branch padrão.

## Kafka em prática

7 tópicos existem hoje no código; a maioria é publicada como trilha de auditoria, sem consumidor real (a integração entre serviços é majoritariamente HTTP síncrono). O único tópico com produtor e consumidor implementados é `channel.webhook.received`, usado como fila durável de entrada do `whatsapp-bff`. Matriz completa em [`docs/contracts/kafka-events.md`](docs/contracts/kafka-events.md).

## Dados e bancos

Kafka, PostgreSQL, MongoDB, Redis e OpenSearch são efetivamente usados por código de aplicação hoje: PostgreSQL pelo `conversation-audit-service` (`ops.audit_events`, um evento de jornada por linha), pelo `conversation-handoff-service` (`conversation.handoffs`, um pedido de transferência humana por linha), pelo `conversation-orchestrator` (Inbox + Outbox transacional da ingestão de mensagens) e pelo `renegotiation-service` (lease de idempotência de `simular_proposta`); MongoDB pelo `conversation-memory-service` (histórico de mensagens e memória de longo prazo); Redis pelo `conversation-memory-service` (sessão ativa de conversa) e pelo `whatsapp-bff` (idempotência de envio outbound); OpenSearch pelo `knowledge-service` (busca vetorial k-NN de FAQ, um índice por tenant). Detalhe em [`docs/contracts/data-stores.md`](docs/contracts/data-stores.md) — pode estar desatualizado sobre os usos mais recentes.

## Contratos

- [Mapa de serviços](docs/contracts/services-map.md) — todos os serviços implementados e as dependências assumidas.
- [Eventos Kafka](docs/contracts/kafka-events.md) — matriz produtor/consumidor/status.
- [Datastores](docs/contracts/data-stores.md) — o que é provisionado vs. o que é usado.

## Segurança

Validação HMAC do webhook, exclusão de dados sensíveis dos eventos de auditoria, JWT interno HS256 (com claim `tenant_id` assinada e verificada) exigido em praticamente todo endpoint entre serviços — com um segredo distinto por par (emissor, audiência), não mais um segredo único compartilhado por toda a plataforma (ver `per-service-internal-auth-secrets` em `openspec/changes/`) — e tokens `governed_tool` com autorização por estágio de jornada entre `agent-runtime-renegotiation` → `tool-service-renegotiation` → `renegotiation-service`. Lacunas conhecidas que permanecem: sem criptografia em repouso, e o HS256 por par ainda é simétrico sem rotação automatizada. Detalhe em [`docs/security/security-architecture.md`](docs/security/security-architecture.md) — **atenção**: esse documento pode estar desatualizado sobre o que já foi implementado; ver `docs/validation/` para o estado confirmado por execução real mais recente.

## ADRs

Decisões de arquitetura já implementadas no código, registradas retroativamente em [`docs/adr/`](docs/adr/): Kafka como fila durável de webhook, arquitetura hexagonal nos serviços .NET, MCP para tool-calling governado, e a filosofia de resiliência "catch-log-continue".

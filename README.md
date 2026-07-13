# conversational-ai-demo-arch

Arquitetura de referência para plataformas de IA conversacional utilizando agentes, MCP, RAG, WhatsApp, APIs corporativas e observabilidade ponta a ponta.

## Documentação

- [Contexto de negócio](docs/context/business-context.md) — jornadas, personas e escopo.
- [C4 nível 1 (contexto)](docs/architecture/c4-context.md) e [diagramas C4](docs/architecture/C4/) (`.puml`/`.svg`/`.png`).
- [Diagramas de sequência da jornada](docs/architecture/sequence-diagrams.md) — passo a passo técnico, do webhook do WhatsApp até a consulta de débitos/elegibilidade.
- [Páginas de referência por serviço](docs/services/) — responsabilidade, APIs, eventos e regras de negócio de cada um dos 6 serviços implementados.
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
| MongoDB | `localhost:27017` | `admin/admin` |
| PostgreSQL | `localhost:5432` | `postgres/postgres` |
| Kafka | `localhost:29092` | - |
| Jaeger UI | http://localhost:16686 | - |
| Loki | http://localhost:3100 | - |
| Prometheus | http://localhost:9090 | - |
| Grafana | http://localhost:3000 | `admin/admin` |

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

Detalhe de responsabilidades, APIs e regras de negócio de cada um em [`docs/services/`](docs/services/).

## Kafka em prática

7 tópicos existem hoje no código; a maioria é publicada como trilha de auditoria, sem consumidor real (a integração entre serviços é majoritariamente HTTP síncrono). O único tópico com produtor e consumidor implementados é `channel.webhook.received`, usado como fila durável de entrada do `whatsapp-bff`. Matriz completa em [`docs/contracts/kafka-events.md`](docs/contracts/kafka-events.md).

## Dados e bancos

Só o Kafka é efetivamente usado por código de aplicação hoje — PostgreSQL, MongoDB e Redis estão provisionados (com schema pronto) mas não consumidos por nenhum serviço implementado. Detalhe em [`docs/contracts/data-stores.md`](docs/contracts/data-stores.md).

## Contratos

- [Mapa de serviços](docs/contracts/services-map.md) — todos os serviços implementados e as dependências assumidas.
- [Eventos Kafka](docs/contracts/kafka-events.md) — matriz produtor/consumidor/status.
- [Datastores](docs/contracts/data-stores.md) — o que é provisionado vs. o que é usado.

## Segurança

Validação HMAC do webhook, exclusão de dados sensíveis dos eventos de auditoria, e as lacunas conhecidas (sem autenticação entre serviços internos, sem criptografia em repouso) em [`docs/security/security-architecture.md`](docs/security/security-architecture.md).

## ADRs

Decisões de arquitetura já implementadas no código, registradas retroativamente em [`docs/adr/`](docs/adr/): Kafka como fila durável de webhook, arquitetura hexagonal nos serviços .NET, MCP para tool-calling governado, e a filosofia de resiliência "catch-log-continue".

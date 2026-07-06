# conversational-ai-demo-arch

Arquitetura de referência para plataformas de IA conversacional utilizando agentes, MCP, RAG, WhatsApp, APIs corporativas e observabilidade ponta a ponta.

## Documentação

- [Contexto de negócio](docs/context/business-context.md) — jornadas, personas e escopo.
- [C4 nível 1 (contexto)](docs/architecture/c4-context.md) e [diagramas C4](docs/architecture/C4/) (`.puml`/`.svg`/`.png`).
- [Diagramas de sequência da jornada](docs/architecture/sequence-diagrams.md) — passo a passo técnico, do webhook do WhatsApp até a consulta de débitos/elegibilidade.
- [Runbook do ambiente local](docs/runbook.md) — como subir a infraestrutura e os serviços de aplicação.

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

O Prometheus coleta métricas dele mesmo, do Jaeger e de uma aplicação exposta no host em `localhost:8080/metrics`.

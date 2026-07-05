# conversational-ai-demo-arch

Arquitetura de referência para plataformas de IA conversacional utilizando agentes, MCP, RAG, WhatsApp, APIs corporativas e observabilidade ponta a ponta.

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

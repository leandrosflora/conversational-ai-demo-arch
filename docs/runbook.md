# Runbook — Plataforma de IA Conversacional P1

Este documento descreve o **estado implementado** após os hardenings P0/P1. A arquitetura-alvo está em `docs/architecture/C4/c4-container-target.puml`; não use o diagrama-alvo para operar o ambiente atual.

## 1. Pré-requisitos e layout

Os repositórios devem estar como pastas irmãs:

```text
workspace/
├── conversational-ai-demo-arch/
├── whatsapp-bff/
├── conversation-orchestrator/
├── agent-runtime-renegotiation/
├── tool-service-renegotiation/
├── renegotiation-service/
├── knowledge-service/
├── conversation-memory-service/
├── conversation-audit-service/
├── conversation-handoff-service/
└── core-bancario-mock/
```

O repositório `core-bancario-mock` não está conectado à automação que gerou este P1. O Renegotiation Service já envia JWT e tenant ao mock, mas o mock ainda não valida o token nem expõe health/readiness/metrics padronizados.

## 2. Configuração obrigatória

Crie `.env` na raiz de `conversational-ai-demo-arch`:

```dotenv
INTERNAL_AUTH_SIGNING_KEY=<segredo-aleatório-com-pelo-menos-32-bytes>
DEFAULT_TENANT_ID=00000000-0000-0000-0000-000000000001
OPENAI_API_KEY=
MOCK_AGENT_ENABLED=true
```

Gere uma chave local sem versioná-la:

```bash
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

O Compose falha imediatamente se `INTERNAL_AUTH_SIGNING_KEY` não estiver definido. Em produção, substitua o segredo HMAC compartilhado por workload identity/mTLS ou por chaves assimétricas gerenciadas por um IdP.

> **Validado em 2026-07-18** ([relatório](validation/2026-07-18-p1-hardening-e2e.md)): até essa data, `.env.example` não documentava `INTERNAL_AUTH_SIGNING_KEY` nem `DEFAULT_TENANT_ID` — quem seguisse só o `.env.example` para montar o `.env` local não tinha como saber que essas variáveis existiam ou eram obrigatórias, até o `docker compose` falhar na interpolação com `Set INTERNAL_AUTH_SIGNING_KEY in .env`. Corrigido em `.env.example`.

## 3. Subida do ambiente

```bash
docker compose up -d --build
```

Verifique:

```bash
docker compose ps
```

A sobreposição `docker-compose.override.yml` é carregada automaticamente e adiciona:

- configuração JWT interna;
- tenant padrão do canal;
- Inbox PostgreSQL do Orchestrator;
- tópicos Kafka de retry e DLQ;
- segregação multitenant do RAG e da memória.

## 4. Portas

| Serviço | Porta host | Endpoint operacional |
|---|---:|---|
| whatsapp-bff | `5153` | `http://localhost:5153/health/ready` |
| conversation-orchestrator | `5268` | `http://localhost:5268/health/ready` |
| agent-runtime-renegotiation | `8100` | `http://localhost:8100/health/ready` |
| conversation-handoff-service | `8200` | `http://localhost:8200/health/ready` |
| conversation-audit-service | `8300` | `http://localhost:8300/health/ready` |
| tool-service MCP | `8400` | protegido; health no REST |
| tool-service REST | `8401` | `http://localhost:8401/health/ready` |
| knowledge-service | `8500` | `http://localhost:8500/health/ready` |
| conversation-memory-service | `8600` | `http://localhost:8600/health/ready` |
| renegotiation-service | `5266` | `http://localhost:5266/health/ready` |
| Core mock | `9401`–`9404` | pendente de padronização |
| Kafka UI | `8080` | UI |
| Jaeger | `16686` | UI |
| Prometheus | `9090` | UI |
| Grafana | `3001` | UI |

Todos os serviços P1 expõem:

- `GET /health/live`: processo vivo;
- `GET /health/ready`: configuração e dependências mínimas prontas;
- `GET /metrics`: formato Prometheus.

## 5. Autenticação interna

As APIs internas usam JWT HS256 de curta duração:

- `iss`: `conversational-ai-platform`;
- `sub`: serviço chamador;
- `aud`: serviço destino;
- validade padrão: 300 segundos;
- tenant: header `X-Tenant-Id`.

Endpoints públicos:

- handshake e webhook do WhatsApp, protegidos por verify token/HMAC;
- `/health/live`, `/health/ready` e `/metrics`;
- documentação Swagger em desenvolvimento, conforme cada serviço.

Endpoints agora protegidos incluem:

- `POST /internal/messages`;
- `POST /messages` do Orchestrator;
- `POST /process` do Agent Runtime;
- MCP e REST do Tool Service;
- `GET /search` e `POST /admin/reindex`;
- todas as APIs do Memory Service;
- Audit, Handoff e Renegotiation Service.

Uma chamada direta sem token deve responder `401`; sem `X-Tenant-Id`, `400`.

## 6. Multitenancy

### 6.1 Sessões e memória

Redis usa:

```text
tenant:{tenantId}:session:{conversationId}
```

MongoDB usa `tenantId` como parte das consultas e índices. O tenant de query/body não é aceito como fonte independente: o header autenticado é canônico e divergências são rejeitadas.

### 6.2 RAG

O Knowledge Service cria um índice OpenSearch físico por tenant:

```text
faq_chunks-{tenant-normalizado}
```

Os PDFs devem ficar em:

```text
knowledge-service/data/faq_pdfs/<tenantId>/*.pdf
```

Para compatibilidade, apenas o tenant padrão pode ler PDFs diretamente da raiz antiga `data/faq_pdfs/`.

Reindexação exige JWT e tenant. Execute a partir de um cliente técnico autorizado; não exponha `/admin/reindex` na internet.

## 7. Kafka, retry e DLQ

Tópicos da entrada:

| Tópico | Finalidade |
|---|---|
| `channel.webhook.received` | webhook bruto confirmado antes do ACK à Meta |
| `channel.webhook.received.retry` | retry durável após falha transitória |
| `channel.webhook.received.dlq` | poison message ou tentativas esgotadas |

Política atual:

1. JSON inválido ou payload nulo vai diretamente para DLQ.
2. Falha transitória publica uma nova mensagem no tópico de retry.
3. O contador `x-delivery-attempt` acompanha a mensagem.
4. Após cinco tentativas, a mensagem vai para DLQ.
5. O offset original só é commitado depois que retry ou DLQ foi confirmado pelo broker.
6. Se a publicação de retry/DLQ falhar, o consumer faz replay do registro original.

Inspecione a DLQ:

```bash
MSYS_NO_PATHCONV=1 docker exec conversational-ai-kafka \
  /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka:9092 \
  --topic channel.webhook.received.dlq \
  --from-beginning
```

A DLQ preserva o payload e adiciona headers com motivo, tópico, partição e offset de origem. Reprocessamento deve ser uma operação administrativa explícita; não crie um loop automático DLQ → entrada.

## 8. Tracing distribuído

Publicadores Kafka adicionam `traceparent` e, quando existente, `tracestate`. O consumer do BFF extrai o contexto e cria um span `Consumer`, portanto o salto:

```text
Webhook HTTP → Kafka → Consumer → Orchestrator
```

continua o mesmo trace W3C. Eventos de agente, tools, intenção e mudança de estado também carregam contexto de trace e tenant.

Consulte o Jaeger em `http://localhost:16686`.

## 9. Métricas

Prometheus coleta todos os nove serviços de aplicação. Principais grupos:

- HTTP: volume, status e duração;
- canal: persistência Kafka, retries, DLQ e poison messages;
- Orchestrator: Inbox, outcomes, handoffs e duração;
- Agent Runtime: decisões, handoffs e tempo de processamento;
- Tool Service: execução e duração por tool;
- Knowledge: buscas, quantidade de resultados e reindexações;
- Memory: operações Redis/Mongo por tipo e resultado;
- Audit/Handoff: gravações e indisponibilidade;
- Renegotiation: volume e duração das capacidades.

Consultas úteis:

```promql
rate(channel_webhook_dead_letter_total[5m])
rate(orchestrator_processing_failures_total[5m])
sum by (reason) (rate(agent_runtime_handoffs_total[15m]))
sum by (tool, outcome) (rate(tool_service_executions_total[5m]))
```

## 10. Checklist E2E

1. `docker compose ps` sem crash loops.
2. Todos os `/health/ready` acessíveis retornam `200`.
3. Prometheus mostra todos os targets como `UP`.
4. Webhook válido retorna `200`; Kafka indisponível retorna `503`.
5. A mensagem aparece no Orchestrator uma única vez.
6. Redis contém chave com prefixo do tenant.
7. MongoDB contém `tenantId` correto.
8. Busca RAG não retorna chunks de outro tenant.
9. Jaeger mostra continuidade no salto Kafka.
10. Forçar JSON inválido no tópico envia o registro para DLQ.
11. Repetir Audit/Handoff com a mesma `Idempotency-Key` não duplica linhas.

## 11. Limitações que ainda impedem produção plena

- Core mock não valida JWT e não possui endpoints operacionais padronizados.
- JWT HMAC compartilhado é aceitável para POC endurecida, mas não é a arquitetura-alvo.
- Handoff ainda persiste um pedido; não integra uma plataforma humana real.
- OpenSearch local opera sem plugin de segurança.
- Não há Schema Registry para eventos Kafka.
- Não há Kubernetes, políticas de rede, mTLS, rotação automática de chaves ou SIEM.
- Não há CI obrigatório executando build, testes, SAST, secret scanning e testes de contrato.

## 12. Encerramento e reset

```bash
docker compose down
```

Reset completo, incluindo dados:

```bash
docker compose down -v
```

Scripts de inicialização PostgreSQL/Mongo executam somente quando os volumes estão vazios. Os serviços P0 também aplicam migrações idempotentes necessárias para volumes existentes.

## 13. Troubleshooting (achados da validação P1)

Achados de [`validation/2026-07-18-p1-hardening-e2e.md`](validation/2026-07-18-p1-hardening-e2e.md), já corrigidos no código/config deste repositório — registrados aqui como referência rápida caso reapareçam num checkout mais antigo ou numa mudança futura similar.

### `kafka-init` sai com `exit 2` / `whatsapp-bff` nunca sobe

Sintoma: `docker logs conversational-ai-kafka-init` mostra `syntax error near unexpected token` e o `whatsapp-bff` fica parado em `Waiting` (depende de `kafka-init: condition: service_completed_successfully`). Causa: o `command` do `kafka-init` em `docker-compose.override.yml` é um escalar YAML dobrado (`>`) — linhas com a mesma indentação da linha-base viram uma só linha com espaço, mas linhas **mais indentadas** (ex.: cada tópico em sua própria linha, ou cada flag do `kafka-topics.sh` na sua) são preservadas literalmente com quebra de linha, produzindo bash inválido. Ao editar esse `command`, mantenha a lista de tópicos do `for topic in ...; do` e os argumentos do `kafka-topics.sh` cada um em uma única linha (mesma indentação da linha-base) — nunca um item por linha.

### `/health/ready` sempre `503 {"failures":["kafka_unavailable"]}` em `agent-runtime-renegotiation` ou `tool-service-renegotiation`, mesmo com Kafka saudável (`docker compose ps` mostra `healthy`)

Causa: `producer.list_topics(1)` (confluent-kafka-python) passa `1` como o parâmetro posicional `topic` (que espera `str`/`None`), não como `timeout` — `TypeError` engolido pelo `except Exception` do handler. Use sempre `list_topics(timeout=N)` como keyword argument.

### Compose falha com `Set INTERNAL_AUTH_SIGNING_KEY in .env`

Ver §2 — variável obrigatória, gere com `python -c "import secrets; print(secrets.token_urlsafe(48))"` e adicione ao `.env` (não ao `.env.example`, que é versionado).

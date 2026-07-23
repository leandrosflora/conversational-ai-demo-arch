# Runbook — Plataforma de IA Conversacional P0/P1

Este documento descreve o estado implementado nos branches `agent/p0-consistency-policy`. A arquitetura-alvo permanece em `docs/architecture/C4/c4-container-target.puml`.

## 1. Repositórios e implantação coordenada

Os repositórios devem ficar como pastas irmãs:

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

Os contratos de tenant e policy mudaram em toda a cadeia. Não implante somente um serviço P0. O conjunto precisa ser validado e liberado de forma coordenada.

O Renegotiation Service envia JWT, tenant e `Idempotency-Key`, mas o `core-bancario-mock` ainda não valida integralmente essas garantias.

## 2. Configuração obrigatória

Crie `.env` na raiz de `conversational-ai-demo-arch`. Desde a mudança `per-service-internal-auth-secrets`, cada par (emissor, audiência) de chamada interna tem seu próprio segredo — não existe mais um `INTERNAL_AUTH_SIGNING_KEY` único. Gere os 10 valores (cada um com pelo menos 32 bytes, ex: `python -c "import secrets; print(secrets.token_urlsafe(48))"`); a lista completa e comentada está em `.env.example`:

```dotenv
INTERNAL_AUTH_SECRET_WHATSAPP_BFF__CONVERSATION_ORCHESTRATOR=<segredo>
INTERNAL_AUTH_SECRET_CONVERSATION_ORCHESTRATOR__WHATSAPP_BFF=<segredo>
INTERNAL_AUTH_SECRET_CONVERSATION_ORCHESTRATOR__AGENT_RUNTIME_RENEGOTIATION=<segredo>
INTERNAL_AUTH_SECRET_CONVERSATION_ORCHESTRATOR__CONVERSATION_AUDIT_SERVICE=<segredo>
INTERNAL_AUTH_SECRET_CONVERSATION_ORCHESTRATOR__CONVERSATION_HANDOFF_SERVICE=<segredo>
INTERNAL_AUTH_SECRET_CONVERSATION_ORCHESTRATOR__CONVERSATION_MEMORY_SERVICE=<segredo>
INTERNAL_AUTH_SECRET_AGENT_RUNTIME_RENEGOTIATION__TOOL_SERVICE_RENEGOTIATION=<segredo>
INTERNAL_AUTH_SECRET_AGENT_RUNTIME_RENEGOTIATION__KNOWLEDGE_SERVICE=<segredo>
INTERNAL_AUTH_SECRET_AGENT_RUNTIME_RENEGOTIATION__CONVERSATION_MEMORY_SERVICE=<segredo>
INTERNAL_AUTH_SECRET_TOOL_SERVICE_RENEGOTIATION__RENEGOTIATION_SERVICE=<segredo>
DEFAULT_TENANT_ID=00000000-0000-0000-0000-000000000001
OPENAI_API_KEY=
MOCK_AGENT_ENABLED=true
```

Gere uma chave local:

```bash
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

`DEFAULT_TENANT_ID` precisa ser UUID não vazio. Todos os serviços comparam o header `X-Tenant-Id` com a claim assinada `tenant_id`.

## 3. Build e testes obrigatórios antes do merge

### .NET

Execute em cada repositório .NET:

```bash
dotnet restore
dotnet build --no-restore
dotnet test --no-build
```

Repositórios:

- `whatsapp-bff`;
- `conversation-orchestrator`;
- `renegotiation-service`;
- `conversation-audit-service`;
- `conversation-handoff-service`.

### Python

Em cada serviço Python:

```bash
python -m venv .venv
# Linux/macOS
source .venv/bin/activate
# Windows PowerShell
# .venv\Scripts\Activate.ps1

pip install -r requirements.txt
pip install -r requirements-dev.txt
pytest -q
```

Repositórios:

- `agent-runtime-renegotiation`;
- `tool-service-renegotiation`;
- `knowledge-service`;
- `conversation-memory-service`.

## 4. Subida do ambiente

```bash
docker compose up -d --build
```

Verifique:

```bash
docker compose ps
```

A sobreposição `docker-compose.override.yml` adiciona:

- autenticação interna e tenant padrão do canal;
- Redis para idempotência de respostas outbound;
- PostgreSQL para Inbox, estado versionado, Outbox e idempotência de simulação;
- migração MongoDB para unicidade tenant-scoped;
- tópicos Kafka de retry e DLQ.

## 5. Portas

| Serviço | Porta host | Readiness |
|---|---:|---|
| whatsapp-bff | `5153` | `http://localhost:5153/health/ready` |
| conversation-orchestrator | `5268` | `http://localhost:5268/health/ready` |
| agent-runtime-renegotiation | `8100` | `http://localhost:8100/health/ready` |
| conversation-handoff-service | `8200` | `http://localhost:8200/health/ready` |
| conversation-audit-service | `8300` | `http://localhost:8300/health/ready` |
| tool-service MCP | `8400` | health no REST |
| tool-service REST | `8401` | `http://localhost:8401/health/ready` |
| knowledge-service | `8500` | `http://localhost:8500/health/ready` |
| conversation-memory-service | `8600` | `http://localhost:8600/health/ready` |
| renegotiation-service | `5266` | `http://localhost:5266/health/ready` |
| Core mock | `9401`–`9404` | pendente |
| Kafka UI | `8080` | UI |
| Jaeger | `16686` | UI |
| Prometheus | `9090` | UI |
| Grafana | `3001` | UI |

## 6. Tenant e autenticação

Chamadas internas usam:

```text
Authorization: Bearer <JWT>
X-Tenant-Id: <UUID>
```

O JWT inclui:

```text
iss, sub, aud, iat, exp, jti, tenant_id
```

Resultados esperados:

- sem token: `401`;
- tenant ausente ou não UUID: `400`;
- header diferente da claim: `403`.

### Tokens de tools

Agent Runtime → Tool Service:

```text
token_use=tool_execution
conversation_id
message_id
journey_stage
journey_version
confirmation_message_id (quando aplicável)
```

Tool Service → Renegotiation Service:

```text
token_use=governed_tool
tool_name
policy_id
mesmo contexto da jornada
```

O `policy_id` precisa ser igual ao `Idempotency-Key` da operação.

## 7. Persistência e migrações

### PostgreSQL

Tabelas P0:

```text
ops.message_inbox
ops.conversation_state
ops.orchestrator_outbox
ops.renegotiation_idempotency
```

Índices compostos:

```text
ops.audit_events        (tenant_id, idempotency_key)
conversation.handoffs   (tenant_id, idempotency_key)
```

Consulte o estado:

```sql
SELECT tenant_id, message_id, status, completion_reason, attempt_count, last_error
FROM ops.message_inbox
ORDER BY received_at DESC;

SELECT tenant_id, conversation_id, journey_stage, version,
       last_received_at, processing_message_id, processing_lease_until
FROM ops.conversation_state;

SELECT tenant_id, conversation_id, journey_version, effect_type, status,
       attempt_count, next_attempt_at, last_error
FROM ops.orchestrator_outbox
ORDER BY created_at;

SELECT tenant_id, idempotency_key, request_hash, status, last_error, completed_at
FROM ops.renegotiation_idempotency
ORDER BY created_at DESC;
```

### MongoDB

A coleção `conversation_messages` deve possuir:

```text
unique partial index: (tenantId, externalMessageId)
```

O índice global legado `externalMessageId_1` deve ter sido removido.

### OpenSearch

O índice físico usa UUID canônico:

```text
faq_chunks-00000000-0000-0000-0000-000000000001
```

## 8. Semântica do Inbox e Outbox

Um `202` do Orchestrator significa:

> estado e efeitos obrigatórios foram registrados na mesma transação.

Não significa que WhatsApp, Memory, Audit ou Handoff já concluíram.

O dispatcher:

- usa lease e `FOR UPDATE SKIP LOCKED`;
- tenta cada efeito at-least-once;
- marca sucesso como `published`;
- marca falha como `failed` com backoff;
- bloqueia versões posteriores da conversa enquanto uma versão anterior não estiver totalmente publicada.

### Efeito permanentemente falho

Um efeito anterior falho bloqueia versões posteriores da mesma conversa. Procedimento:

1. identificar a causa pelo `last_error` e logs;
2. corrigir o downstream/configuração;
3. ajustar `next_attempt_at=now()` ou aguardar o backoff;
4. não marcar `published` manualmente sem evidência de que o destino recebeu ou deduplicará o efeito.

## 9. Idempotência dos destinos

| Destino | Chave |
|---|---|
| BFF outbound | Redis por tenant + hash da chave da Outbox |
| Memory | `(tenantId, externalMessageId)` |
| Audit | `(tenant_id, idempotency_key)` |
| Handoff | `(tenant_id, idempotency_key)` |
| Simulação | `(tenant_id, operation, idempotency_key)` + request hash |

## 10. Ordenação e mensagens atrasadas

O Orchestrator mantém uma versão por conversa.

- apenas uma mensagem mantém lease ativo;
- conclusão exige a versão esperada;
- evento anterior ou igual ao último `(receivedAt, messageId)` é concluído com `completion_reason=late_message`;
- late message não chama Agent Runtime nem executa tools.

Teste recomendado:

1. envie mensagem A e force falha antes da conclusão;
2. envie mensagem B para a mesma conversa;
3. confirme `409`/retry enquanto A mantém lease;
4. reprocesse A;
5. confirme que B recebe a versão seguinte;
6. injete novamente A e confirme `late_message`.

## 11. Policy enforcement

Testes mínimos:

1. `confirmar_acordo` em `EligibilityChecked` deve ser negada;
2. confirmação sem `confirmation_message_id` deve ser negada;
3. confirmação com ID diferente da mensagem atual deve ser negada;
4. `policy_id` diferente do `Idempotency-Key` deve ser negado pelo Renegotiation Service;
5. token com caller diferente do Agent Runtime/Tool Service deve ser negado;
6. simulação em estágio permitido deve gerar a mesma chave para o mesmo contexto/request.

## 12. Simulação idempotente e reconciliação

Comportamentos:

- chave nova: executa e persiste a resposta;
- chave concluída: retorna a mesma resposta sem Core;
- mesma chave com payload diferente: `409` não retryable;
- chave `processing` ou `failed`: `409` retryable, mas não é readquirida automaticamente.

### Reconciliação de resultado ambíguo

Enquanto o Core mock não validar idempotência:

1. não apague a linha nem mude para `failed` esperando retry automático;
2. consulte o Core/logs para verificar se a simulação foi criada;
3. se criada, grave a resposta correspondente e marque `completed` por procedimento auditado;
4. se comprovadamente não criada, gere uma nova operação com nova mensagem/contexto e nova chave;
5. nunca reutilize a chave antiga com parâmetros diferentes.

## 13. Kafka, retry e DLQ

Tópicos:

| Tópico | Finalidade |
|---|---|
| `channel.webhook.received` | entrada confirmada antes do ACK |
| `channel.webhook.received.retry` | retry durável |
| `channel.webhook.received.dlq` | poison ou tentativas esgotadas |

O offset original só é commitado após confirmação de retry/DLQ ou `202` do Orchestrator.

## 14. Métricas e alertas mínimos

Adicionar alertas para:

```promql
rate(channel_webhook_dead_letter_total[5m]) > 0
rate(orchestrator_processing_failures_total[5m]) > 0
rate(orchestrator_late_messages_total[5m]) > 0
rate(orchestrator_outbox_dispatch_total{outcome="failed"}[5m]) > 0
```

Também monitorar via SQL:

- idade do efeito não publicado mais antigo;
- quantidade de efeitos `failed`;
- conversas com `processing_lease_until < now()`;
- simulações `processing`/`failed` antigas.

## 15. Checklist E2E P0

1. todos os builds e testes passam;
2. todos os readiness retornam `200`;
3. token sem `tenant_id` é rejeitado;
4. header/claim divergentes retornam `403`;
5. falha do BFF outbound deixa efeito na Outbox e não perde resposta;
6. replay da resposta retorna o mesmo `messageId` do Redis;
7. falha de Memory/Audit/Handoff deixa efeito retryable;
8. a versão seguinte fica bloqueada enquanto efeito anterior falha;
9. mensagens concorrentes da mesma conversa não chamam o agente em paralelo;
10. mensagem atrasada recebe `late_message`;
11. simulação repetida retorna resposta persistida;
12. simulação com mesma chave e parâmetros diferentes retorna conflito;
13. confirmação sem evidência assinada é negada;
14. índices e chaves não colidem entre dois tenants.

## 16. Limitações restantes

- Core mock ainda não valida JWT, policy proof e idempotência;
- HS256 compartilhado não é identidade final;
- Handoff não integra plataforma humana;
- Kafka/OpenSearch/Redis/PostgreSQL locais não representam configuração de produção;
- não há CI obrigatório, SAST, SCA, SBOM ou assinatura de imagem;
- alertas e procedimento automatizado de replay/reconciliação ainda não estão provisionados.

## 17. Reset

```bash
docker compose down
```

Reset completo:

```bash
docker compose down -v
```

Scripts de inicialização executam apenas em volumes vazios. Os serviços aplicam migrações idempotentes para volumes existentes, mas esse caminho precisa ser testado antes do merge.

## 18. Troubleshooting conhecido

### `kafka-init` sai com `exit 2`

Mantenha o `for topic in ...; do` e o comando `kafka-topics.sh` em linhas YAML que sejam dobradas corretamente. Não quebre cada argumento com indentação adicional.

### Readiness Python acusa Kafka indisponível com broker saudável

Use `producer.list_topics(timeout=1)`. O argumento posicional `1` seria interpretado como tópico.

### Compose falha com `Set INTERNAL_AUTH_SECRET_<PAR> in .env`

Falta uma das 10 variáveis de segredo por par em `.env` — veja a lista completa em `.env.example`. Cada uma é independente; não versionar valores reais.

# Validação E2E pós-hardening P1 (JWT + multitenancy) — 2026-07-18

Contexto: as 9 repos de aplicação receberam, em sequência, a change de hardening P1 (autenticação JWT HS256 interna + propagação de tenant em todos os saltos — ver `docs/runbook.md` §5-6 e `docs/security/security-architecture.md`). Esta validação cobre o rebuild completo do ambiente local a partir dessas mudanças e um teste E2E real (webhook assinado → `whatsapp-bff` → Kafka → `conversation-orchestrator` → `agent-runtime-renegotiation` (OpenAI real) → `tool-service-renegotiation` → `renegotiation-service` → volta ao `whatsapp-bff` → WhatsApp Cloud API), com o objetivo de responder: **o ambiente sobe do zero com essas mudanças, e a jornada continua funcionando de ponta a ponta?**

Resposta curta: não, não sem correções — o ambiente não subia (`docker compose` falhava na interpolação, dois serviços não compilavam, um terceiro engasgava a inicialização do `whatsapp-bff`). Depois de 6 correções (detalhadas abaixo), a jornada completa foi confirmada funcionando com autenticação real em todos os saltos.

## Método

Stack subida via `docker compose up -d --build` (não `dotnet run` local), com `MOCK_AGENT_ENABLED=false` e uma `OPENAI_API_KEY` real — ou seja, raciocínio real da OpenAI, não o fallback determinístico. Dois testes E2E completos foram executados via webhook HMAC assinado contra `whatsapp-bff`, com números de telefone sintéticos distintos a cada rodada (para não herdar estado de jornada de rodadas anteriores).

## Bugs encontrados e corrigidos

Nenhum destes é cosmético — cada um bloqueava build, subida do ambiente, ou dava um falso-negativo de saúde.

### 1. `.env` sem `INTERNAL_AUTH_SIGNING_KEY` (bloqueava `docker compose` inteiro)

`docker-compose.override.yml` passou a exigir `INTERNAL_AUTH_SIGNING_KEY` via sintaxe `${INTERNAL_AUTH_SIGNING_KEY:?Set INTERNAL_AUTH_SIGNING_KEY in .env}` em 9 serviços, mas nada gerava ou documentava esse segredo automaticamente — `docker compose` falhava na interpolação antes mesmo de tentar subir um container. `.env.example` também não mencionava a variável (nem `DEFAULT_TENANT_ID`). Corrigido: chave gerada localmente (`python -c "import secrets; print(secrets.token_urlsafe(48))"`, conforme `runbook.md` §2) e adicionada ao `.env` local; `.env.example` atualizado com as duas variáveis e um comentário explicando a exigência.

### 2. `renegotiation-service/Program.cs` não compilava (`CS0266`)

```
error CS0266: Cannot implicitly convert type 'IHttpStandardResiliencePipelineBuilder' to 'IHttpClientBuilder'
```

A função local `AddCoreClient<TClient, TImplementation, TOptions>` declarava retorno `IHttpClientBuilder` e fazia `return services.AddHttpClient(...).AddHttpMessageHandler(...).AddStandardResilienceHandler(...)` — mas `AddStandardResilienceHandler` no `Microsoft.Extensions.Http.Resilience` 10.7.0 retorna `IHttpStandardResiliencePipelineBuilder`, um tipo diferente. Nenhum dos 4 call sites usava o valor de retorno. Corrigido trocando o retorno da função local para `void` (linha ~37 de `Program.cs`).

### 3. `conversation-orchestrator/Platform/PlatformServices.cs` não compilava (`CS1061`)

```
error CS1061: 'IProducer<string, string>' does not contain a definition for 'GetMetadata'
```

O endpoint `/health/ready` chamava `producer.GetMetadata(...)` diretamente na interface `IProducer<string,string>`, que não expõe esse método (só a implementação concreta/`IAdminClient` expõem). `whatsapp-bff` já resolvia isso corretamente com um `IAdminClient` dedicado — padrão replicado aqui: `IAdminClient` registrado em `Program.cs` e o handler de `/health/ready` trocado para recebê-lo em vez de `IProducer<string,string>`.

### 4. `kafka-init` saía com `exit 2`, travando a subida do `whatsapp-bff`

`docker-compose.override.yml` reescreveu o `command` do `kafka-init` (para incluir os novos tópicos `channel.webhook.received.retry`/`.dlq` e `--partitions 3`) quebrando a lista de tópicos e os argumentos do `kafka-topics.sh` em várias linhas. O dobramento de escalar YAML (`>`) só junta linhas com espaço quando elas têm a **mesma** indentação da linha-base; linhas mais indentadas (como cada tópico em sua própria linha) são preservadas literalmente com sua quebra de linha — o resultado era um script bash inválido (`syntax error near unexpected token`). Como `whatsapp-bff` depende de `kafka-init: condition: service_completed_successfully`, isso travava a subida do serviço inteiro, silenciosamente (o erro só aparecia em `docker logs conversational-ai-kafka-init`). Corrigido devolvendo a lista de tópicos e os argumentos do `kafka-topics.sh` para uma linha única cada, no mesmo padrão que já funcionava no `docker-compose.yml` original.

### 5. `/health/ready` sempre `503 kafka_unavailable` em `agent-runtime-renegotiation` e `tool-service-renegotiation`, mesmo com Kafka saudável

Os dois serviços chamavam `producer.list_topics(1)` (confluent-kafka-python) esperando que `1` fosse o timeout em segundos — mas a assinatura é `list_topics(topic=None, timeout=-1)`, então `1` era interpretado como o parâmetro `topic` (espera `str`/`None`), lançando `TypeError: argument 1 must be str or None, not int`, engolido pelo `except Exception` genérico do handler. Reproduzido isoladamente contra o Kafka real do ambiente para confirmar a causa antes de corrigir. Corrigido nos dois arquivos trocando para `list_topics(timeout=1)` (kwarg explícito).

## Jornada feliz — resultado após as correções

| Etapa | Resultado |
|---|---|
| Handshake de verificação do webhook | **Confirmado** — `200 OK` |
| Webhook assinado (HMAC) → `whatsapp-bff` → Kafka | **Confirmado** — `200 OK` |
| `KafkaWebhookConsumerService` → `POST /messages` no Orchestrator (JWT) | **Confirmado** — `202 Accepted`, sem `401`/`403` |
| Orchestrator → Agent Runtime (JWT, OpenAI real, ~11s) | **Confirmado** — dentro do orçamento de `AttemptTimeout=45s` (ver nota abaixo) |
| Agent Runtime → `tool-service-renegotiation` (JWT via MCP) → `renegotiation-service` (JWT) | **Confirmado** — `consultar_cliente`/`consultar_contratos` retornaram `200 OK` |
| Orchestrator → `conversation-memory-service`, `conversation-audit-service` (JWT) | **Confirmado** — sessão, histórico e evento de auditoria persistidos |
| Orchestrator → `whatsapp-bff` (JWT) → WhatsApp Cloud API real | **Confirmado o alcance**; rejeitado pela Graph API real (`#131030 Recipient phone number not in allowed list`) — **drift esperado**, mesmo comportamento documentado em `docs/services/whatsapp-bff.md` para número de teste sintético não cadastrado na conta de teste, não relacionado à autenticação interna |
| Tenant propagado corretamente (`00000000-0000-0000-0000-000000000001`) em todos os saltos | **Confirmado** — aparece nos logs do Orchestrator e do Agent Runtime |
| Deduplicação via Inbox (Postgres) — mensagem processada uma única vez | **Confirmado** — uma única chamada ao Agent Runtime por `MessageId` (ver achado de duplicação do relatório de 2026-07-13, agora mitigado) |
| `outcome=processed` (não `handoff` por timeout técnico) | **Confirmado** |

### Nota sobre timeout do `AgentRuntimeClient`

Corrigido nesta mesma sessão, antes do hardening ser mesclado: `conversation-orchestrator/Program.cs`, cliente `IAgentRuntimeClient`, agora usa `AttemptTimeout=45s`/`TotalRequestTimeout=60s`/`CircuitBreaker.SamplingDuration=90s` (em vez dos defaults 10s/30s/30s do framework) — necessário porque uma chamada real de ponta a ponta (múltiplos round-trips de OpenAI + tool calls MCP) observada levando ~21-41s, bem acima do `AttemptTimeout` padrão. Ver `docs/services/conversation-orchestrator.md` §"Dependências síncronas" (nota atualizada nesta mesma change) — os demais clientes síncronos do Orchestrator (`whatsapp-bff`, `conversation-memory-service`, `conversation-audit-service`, `conversation-handoff-service`) continuam nos defaults 10s/30s, adequados às suas latências reais (sub-segundo a poucos segundos).

## Suítes de teste (.NET) — quebradas pelo hardening, corrigidas nesta change

`renegotiation-service.Tests` e `conversation-orchestrator.Tests` não compilavam (assinaturas novas — `ConfirmAsync` ganhou `idempotencyKey`, `AgentRuntimeRequest`/`KafkaConversationEventPublisher`/`ConversationMemoryClient` ganharam `TenantId`/`TenantContext`/`PlatformMetrics` obrigatórios). Depois de corrigir a compilação, a suíte inteira de testes de endpoint (`WebApplicationFactory<Program>`) começou a falhar em runtime com `401 Unauthorized` — a política de autorização padrão passou a exigir JWT em toda rota, e nenhum teste emitia token. Duas soluções diferentes, conforme o que cada serviço suporta:

- `conversation-orchestrator` tem `InternalAuth:Enabled` configurável — testes usam `UseSetting("InternalAuth:Enabled", "false")` no host de teste.
- `renegotiation-service` **não tem** esse flag (a `FallbackPolicy` exige usuário autenticado incondicionalmente) — um helper novo (`renegotiation-service.Tests/Testing/TestAuth.cs`) emite um JWT real com a mesma chave/issuer/audience validados pelo serviço, exercitando a autenticação de verdade em vez de contorná-la.

Resultado: `renegotiation-service.Tests` 35/35, `conversation-orchestrator.Tests` 73/73. As suítes Python (`agent-runtime-renegotiation`, `tool-service-renegotiation`, `knowledge-service`, `conversation-memory-service`) não foram auditadas nesta rodada.

## Não verificado nesta rodada

- Suítes de teste Python (`pytest`) dos 4 serviços em Python.
- Caminho de handoff completo (`RequiresHandoff=true`) sob o novo regime de auth — a rodada validada teve `outcome=processed`.
- Rotação/expiração de token JWT (TTL de 300s) sob carga sustentada.
- Comportamento de `/admin/reindex` do `knowledge-service` sob auth (mencionado no runbook como exigindo JWT + tenant, não exercitado aqui).

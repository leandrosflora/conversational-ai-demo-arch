# Runbook — Ambiente Local

Guia operacional para subir, verificar e depurar o ambiente local completo da Plataforma de IA Conversacional: infraestrutura (Docker Compose) + os serviços de aplicação implementados até o momento + o mock do Core Bancário.

Repositórios (todos irmãos, na raiz do workspace `whatsapp/`):

| Serviço | Pasta | Stack | Container? |
|---|---|---|---|
| Channel BFF | `whatsapp-bff/` | .NET 8 | não |
| Conversation Orchestrator | `conversation-orchestrator/` | .NET 8 | não |
| Agent Runtime | `agent-runtime-renegotiation/` | Python / Strands Agents / FastAPI | não |
| Tool Service (MCP) | `tool-service-renegotiation/` | Python / MCP (FastMCP) | não |
| Renegotiation Service | `renegotiation-service/` | .NET 8 | não |
| Core Bancário (mock) | `core-bancario-mock/` | .NET 8 | não |
| Conversation Audit Service | `conversation-audit-service/` | .NET 8 | não |
| Infraestrutura | `conversational-ai-demo-arch/` | Docker Compose | sim |

Todos os serviços de aplicação já têm `Dockerfile` e estão wireados no `docker-compose.yml` (`build: context: ../<pasta>`), inclusive uns aos outros via `depends_on` — ou seja, `docker compose up -d` (seção 2) sobe o stack **inteiro**, apps incluídos, não só a infraestrutura. Este runbook documenta o fluxo alternativo de dev local (seção 3): rodar cada serviço via `dotnet run`/`uvicorn` fora do Docker, apontando para a infraestrutura em containers — útil para depurar/debugar um serviço de cada vez sem rebuild de imagem a cada mudança de código. Ao rodar os dois modos ao mesmo tempo, cuidado com colisão de porta host (as portas mapeadas no compose para os apps coincidem com as usadas pelo `dotnet run`/`uvicorn` local).

---

## 1. Pré-requisitos

- Docker Desktop (Docker Engine 20.10+, Compose v2) rodando.
- .NET 8 SDK (`dotnet --version`).
- Python 3.12 (cada serviço Python tem seu próprio `.venv` já criado em `agent-runtime-renegotiation/.venv` e `tool-service-renegotiation/.venv`). **Não use Python 3.14**: o debugger do Visual Studio 2022 (PTVS/debugpy) ainda não suporta as mudanças internas do módulo `threading` no 3.14 (`AttributeError: '_MainThread' object has no attribute '_handle'` ao encerrar o processo) — [issue conhecida](https://github.com/microsoft/debugpy/issues/1893), corrigida upstream mas ainda não lançada pelo VS.
- Portas livres no host: `5432, 6379, 9092, 29092, 9090, 16686, 27017, 3001, 3100, 4317, 4318, 5153, 8000, 8100, 8300, 8400, 8401, 9400, 9401, 9402, 9403, 9404`.

---

## 2. Subir a infraestrutura

```bash
cd conversational-ai-demo-arch
docker compose up -d
docker compose ps
```

### Serviços e portas

| Serviço | Porta(s) host | Uso |
|---|---|---|
| PostgreSQL | `5432` | estado transacional, auditoria, acordos, handoffs (schemas `identity/conversation/ai/knowledge/integration/ops`) |
| MongoDB | **`27018`** | histórico de mensagens, memória conversacional, LLM runs, tool calls, RAG |
| Redis | `6379` | cache / sessão |
| Kafka | `9092` (interno/containers), `29092` (host) | event streaming |
| OpenSearch | `9200` | busca vetorial k-NN (índice `faq_chunks`, usado pelo `knowledge-service`) |
| Jaeger UI | `16686` | tracing (OTLP em `4317`/`4318`) — os 7 serviços de aplicação exportam traces (variável `Otel:OtlpEndpoint` nos .NET, `OTEL_OTLP_ENDPOINT` nos Python), formando um único trace distribuído por requisição de ponta a ponta |
| Prometheus | `9090` | métricas |
| Grafana | **`3001`** | dashboards (login `admin`/`admin`) |
| Loki | `3100` | logs |

> **Grafana está em `3001`, não `3000`.** A porta 3000 está no range de portas excluídas do Windows nesta máquina (`netsh interface ipv4 show excludedportrange protocol=tcp` — reservada pelo Hyper-V/WinNAT). Ver seção de Troubleshooting.

> **MongoDB está em `27018`, não `27017`.** Esta máquina tem um `mongod.exe` nativo (serviço do Windows) escutando em `127.0.0.1:27017`; o Windows roteia tráfego de loopback para esse bind mais específico em vez do `0.0.0.0:27017` do Docker, então ferramentas como Compass acabavam conectando nesse Mongo antigo e não neste projeto. Ver seção de Troubleshooting.

### Credenciais dos bancos

| Banco | Usuário | Senha | Database |
|---|---|---|---|
| PostgreSQL | `postgres` | `postgres` | `conversational_ai` |
| MongoDB (root) | `admin` | `admin` | authSource `admin` |
| MongoDB (app) | `conversational_ai_app` | `conversational_ai_app` | `conversational_ai`, role `readWrite` |

```bash
psql -h localhost -U postgres -d conversational_ai
mongosh "mongodb://admin:admin@localhost:27018/conversational_ai?authSource=admin"
```

### Inicialização dos bancos

Os scripts em `database/conversational-ai-postgres-init.sql` e `database/conversational-ai-mongodb-init.js` só rodam automaticamente **na primeira inicialização com o volume vazio** (comportamento padrão das imagens oficiais `postgres`/`mongo`). Se os containers já existiam antes de montar esses scripts, é preciso recriar os volumes:

```bash
cd conversational-ai-demo-arch
docker compose stop postgres mongodb
docker compose rm -f postgres mongodb
docker volume rm conversational-ai-demo-arch_postgres-data conversational-ai-demo-arch_mongodb-data
docker compose up -d postgres mongodb
```

Verificação:

```bash
docker exec conversational-ai-postgres psql -U postgres -d conversational_ai -c "\dn"
docker exec conversational-ai-mongodb mongosh conversational_ai -u admin -p admin --authenticationDatabase admin --quiet --eval "db.getCollectionNames()"
```

---

## 3. Subir os serviços de aplicação

Cada serviço precisa rodar em uma porta específica para que a cadeia de chamadas funcione (Channel BFF → Orchestrator → Agent Runtime → Tool Service → Renegotiation Service). **As portas padrão do `dotnet run` (geradas pelo Visual Studio) não coincidem com o que os serviços consumidores esperam** — use sempre `--urls` explícito para os serviços .NET, conforme abaixo.

### 3.0 Core Bancário (mock, .NET) — portas `9401`-`9404`

```bash
cd core-bancario-mock
dotnet run
```

Um único processo escuta nas 4 portas (`builder.WebHost.UseUrls(...)` em `Program.cs`) e simula `ClientApi`, `EligibilityApi`, `ContractingApi` e `FormalizationApi` com dados fake, respondendo sempre `200 OK` — inclusive para os desfechos "negativos" de negócio (cliente não encontrado, não elegível, simulação fora de faixa, etc.), nunca com erro HTTP. Gatilhos para forçar esses desfechos:

| Cenário | Como disparar |
|---|---|
| Cliente não encontrado | `GET /clients/00000000000` |
| Contrato não elegível | `contractId` contendo `inelegivel` |
| Simulação não possível | `installments` ≤ 0 ou > 48 |
| Confirmação não possível | `simulationId` contendo `expired` |
| Documento ainda não disponível | `agreementId` contendo `pendente` |

Suba este mock **antes** do Renegotiation Service (seção 3.1) para que ele responda `200 OK` com dados realistas em vez de `502 Bad Gateway`.

### 3.1 Renegotiation Service (.NET) — porta `9400`

```bash
cd renegotiation-service
dotnet run --urls http://localhost:9400
```

Chama `ClientApi` (`:9401`), `EligibilityApi` (`:9402`), `ContractingApi` (`:9403`), `FormalizationApi` (`:9404`) — servidas pelo mock da seção 3.0. Sem o mock no ar, essas chamadas retornam `502 Bad Gateway` (comportamento de degradação esperado, não um bug).

### 3.2 Tool Service / MCP (Python) — porta `8400` (+ Swagger em `8401`)

```bash
cd tool-service-renegotiation
source .venv/Scripts/activate   # Windows: .venv\Scripts\activate
python -m app.main
```

Serve MCP via streamable-HTTP em `http://localhost:8400/mcp`. Chama `RenegotiationService` em `http://localhost:9400` (seção 3.1).

MCP não tem uma superfície OpenAPI própria (é um protocolo JSON-RPC-like sobre streamable-HTTP, não REST), então `app/main.py` também sobe, no mesmo processo, uma **fachada REST somente para documentação** (`app/rest_api.py`) espelhando as mesmas 7 tools — Swagger UI em `http://localhost:8401/docs`. Ninguém neste workspace consome essa porta; o `agent-runtime-renegotiation` fala MCP (`:8400`) diretamente, não REST. Serve só pra explorar/testar as tools manualmente com uma UI.

### 3.3 Agent Runtime (Python/Strands) — porta `8100`

```bash
cd agent-runtime-renegotiation
source .venv/Scripts/activate
uvicorn app.main:app --host 127.0.0.1 --port 8100
```

Expõe `POST /process`. Chama a OpenAI (precisa de `OPENAI_API_KEY` real — sem ela, a inferência falha e o serviço cai no fallback de handoff com motivo `agent_runtime_unavailable`), o Tool Service via MCP (`:8400`, seção 3.2) e o Knowledge Service (`:8500`, seção 3.8) para busca de FAQ. Esse é FastAPI de verdade (não MCP), então já vem com Swagger UI automático em `http://localhost:8100/docs`, sem precisar de nenhuma configuração extra.

Para testar o fluxo completo sem uma chave da OpenAI, defina `MOCK_AGENT_ENABLED=true` (variável de ambiente, ver `Settings.mock_agent_enabled` em `app/config.py`) antes de subir o serviço:

```bash
MOCK_AGENT_ENABLED=true uvicorn app.main:app --host 127.0.0.1 --port 8100
```

Isso substitui a chamada à OpenAI por uma decisão determinística por palavra-chave (`app/agent/mock.py`) — útil para exercitar webhook → BFF → Orchestrator → Agent Runtime → resposta de ponta a ponta sem depender do modelo real. **Cuidado com a confusão de nomes:** `agent_runtime_unavailable` é usado tanto pelo Agent Runtime (quando a chamada à OpenAI falha, `RequiresHandoff=true` mas `HTTP 200`) quanto pelo sentinel do lado do Orchestrator (`AgentRuntimeResult.Unavailable()`, quando o processo nem responde) — os dois têm a mesma string de motivo mas origens diferentes; veja o log de qual dos dois serviços para diagnosticar.

### 3.4 Audit Service — porta `8300`

O mock que ocupava esta seção (`audit-service-mock`) foi removido: nunca teve pasta neste workspace (`docker compose build` já falhava nele) e o Audit Service real agora existe. Ver seção 3.9 (`conversation-audit-service`) para subir o serviço de verdade — mesma porta `8300`, mesmo contrato `POST /journey-events`.

### 3.5 Conversation Orchestrator (.NET) — porta `8000`

```bash
cd conversation-orchestrator
dotnet run --urls http://localhost:8000
```

Expõe `POST /messages`. Chama `AgentRuntime` (`:8100`, seção 3.3), `ChannelBff` (`:5153`, seção 3.6) e a ainda-inexistente `HandoffService` (`:8200`).

> **Validado em 2026-07-13** ([relatório](validation/2026-07-13-e2e-journey.md)): apesar de o `AuditServiceClient` estar registrado no DI, a chamada `auditClient.RecordJourneyEventAsync(...)` está comentada em `Application/UseCases/IngestMessageUseCase.cs` — o Orchestrator **nunca** chama o `audit-service-mock` (seção 3.4) na prática, mesmo o mock estando no ar e respondendo `200 OK`/logando quando chamado diretamente. Ver detalhe em [`docs/services/conversation-orchestrator.md`](services/conversation-orchestrator.md#dependências-síncronas).
>
> **Atualizado em 2026-07-18**: corrigido. A chamada foi descomentada, `AuditService__BaseUrl` agora aponta para o `conversation-audit-service` real (seção 3.9, porta `8300`) em vez do `audit-service-mock` (removido), e cada mensagem processada grava um evento de jornada de verdade em `ops.audit_events`.

### 3.6 Channel BFF (.NET) — porta `5153` (padrão do `dotnet run`)

```bash
cd whatsapp-bff
dotnet run
```

Expõe `POST /webhooks/whatsapp` (webhook do WhatsApp) e `POST /internal/messages` (callback de resposta).

A entrega ao Orchestrator **não** é mais uma chamada síncrona dentro do próprio request do webhook. O fluxo real é:

1. `POST /webhooks/whatsapp` valida a assinatura HMAC, deduplica por `messageId` e publica o payload bruto no tópico Kafka `channel.webhook.received` (chave de partição = telefone do cliente). Só devolve `200 OK` **depois** que essa publicação é confirmada — se o Kafka estiver fora do ar, devolve `503` para que a Meta reentregue.
2. Um `BackgroundService` interno ao mesmo processo (`KafkaWebhookConsumerService`, grupo de consumidor `whatsapp-bff-webhook-consumer`) lê esse tópico e é quem de fato chama `POST {Orchestrator:BaseUrl}/messages` (`:8000`, seção 3.5).
3. O commit do offset só acontece se **todas** as mensagens daquela entrega forem encaminhadas com sucesso. Se o Orchestrator estiver fora do ar, o consumer dá `Seek` de volta para o mesmo offset e tenta de novo a cada ~2s — ou seja, uma indisponibilidade do Orchestrator trava o processamento desse tópico (backpressure), em vez de perder a mensagem.

Kafka substituiu o que antes era uma fila em memória entre o webhook e o Orchestrator: agora a durabilidade sobrevive a um restart/crash do `whatsapp-bff`.

> Para testar o handshake de verificação do webhook, defina `WhatsApp:VerifyToken` em `appsettings.Development.json` (ou variável de ambiente) e rode com `ASPNETCORE_ENVIRONMENT=Development`.

> **Validado em 2026-07-13** ([relatório](validation/2026-07-13-e2e-journey.md)): sem uma WhatsApp Business Account real configurada, o `POST /internal/messages` chega a ser recebido e processado normalmente, mas a chamada de saída à Graph API real sempre falha (`Unsupported post request...`) e o Orchestrator recebe `502` do `whatsapp-bff` ao tentar entregar a resposta — mesmo comportamento de degradação documentado no item 2 da tabela de dependências síncronas abaixo, só que sempre ativo em ambiente local/demo, não apenas quando o BFF está fora do ar. Não é um bug: é o mesmo tipo de degradação graciosa esperada, só que disparada por falta de credenciais reais em vez de indisponibilidade do processo.
>
> Esse mesmo teste também expôs um problema separado: o cliente HTTP do `whatsapp-bff` para o Orchestrator (`IOrchestratorClient`) tem um `AttemptTimeout` de 10s: quando o processamento síncrono do Orchestrator (que inclui a chamada real à OpenAI) leva mais que isso, o `whatsapp-bff` cancela a chamada e tenta de novo — e como o Orchestrator não deduplica por `MessageId`, a mesma mensagem inbound pode ser processada duas vezes (duas chamadas ao Agent Runtime/OpenAI, duas tentativas de entrega de resposta). Ver achado detalhado no [relatório de validação](validation/2026-07-13-e2e-journey.md).

### 3.7 Conversation Memory Service (Python) — porta `8600`

```bash
cd conversation-memory-service
source .venv/Scripts/activate   # Windows: .venv\Scripts\activate
uvicorn app.main:app --host 127.0.0.1 --port 8600
```

Expõe sessão de conversa (`GET`/`PUT`/`DELETE /sessions/{conversation_id}`, Redis, TTL) e memória durável (`POST`/`GET /conversations/{id}/messages` e `GET`/`PUT /users/{id}/memory`, MongoDB, coleções `conversation_messages`/`agent_memory` já provisionadas em `database/conversational-ai-mongodb-init.js`). FastAPI de verdade — Swagger UI automático em `http://localhost:8600/docs`.

Precisa de Redis (`:6379`) e MongoDB (`:27017`) no ar (seção 2) — sem eles, os endpoints correspondentes respondem `503 Service Unavailable` em vez de travar. **Nenhum outro serviço deste workspace chama o Memory Service ainda**: `conversation-orchestrator` e `agent-runtime-renegotiation` continuam com sessão/memória em processo (`ConcurrentDictionary`/`IMemoryCache`); wireá-los para consumir este serviço é um change futuro (ver `openspec/changes/archive/` quando arquivado).

### 3.8 Knowledge Service (Python) — porta `8500`

```bash
cd knowledge-service
source .venv/Scripts/activate   # Windows: .venv\Scripts\activate
uvicorn app.main:app --host 127.0.0.1 --port 8500
```

Expõe `GET /search?query=...` — o contrato que `agent-runtime-renegotiation`'s `search_knowledge_base` (`app/tools/knowledge.py`) já chama. Na subida (e via `POST /admin/reindex`, a qualquer momento, sem reiniciar), lê todo `.pdf` em `data/faq_pdfs/`, extrai texto (`pypdf`), quebra em chunks e embeda cada um via OpenAI (`text-embedding-3-small`), indexando no OpenSearch (`faq_chunks`, busca k-NN). Reingesta é idempotente por hash de conteúdo do arquivo — só reprocessa o que for novo ou tiver mudado. FastAPI de verdade — Swagger UI automático em `http://localhost:8500/docs`.

Precisa de OpenSearch (`:9200`, seção 2) no ar e de `OPENAI_API_KEY` configurada — sem a chave, a ingestão no startup é pulada (log de aviso, não crash) e `GET /search` responde `503` por requisição; sem OpenSearch, tanto a ingestão quanto `GET /search` respondem/logam `503` em vez de travar. Sem nenhum PDF em `data/faq_pdfs/`, o serviço sobe normalmente e `GET /search` responde `200` com `results: []` para qualquer busca.

> Coloque seus PDFs de FAQ de renegociação em `knowledge-service/data/faq_pdfs/` (ver `README.md` da pasta) antes de subir o serviço, ou rode `POST /admin/reindex` depois de adicioná-los.

### 3.9 Conversation Audit Service (.NET) — porta `8300`

```bash
cd conversation-audit-service
dotnet run --urls http://localhost:8300
```

Expõe `POST /journey-events` — o mesmo contrato que o `AuditServiceClient` do `conversation-orchestrator` já implementa (`ConversationId`, `Intent?`, `Outcome`, `Timestamp`). Cada request bem-sucedido grava uma linha em `ops.audit_events` (PostgreSQL, seção 2), sob o tenant seed `demo-bank` (`00000000-0000-0000-0000-000000000001`); responde `202 Accepted` quando persiste, `400 Bad Request` se faltar `conversationId`/`outcome`/`timestamp`, e `503 Service Unavailable` se o PostgreSQL estiver inacessível.

Precisa de PostgreSQL (`:5432`, seção 2) no ar. **É chamado de verdade pelo `conversation-orchestrator`**: `AuditServiceClient` grava um evento de jornada (`POST /journey-events`) ao final de `IngestMessageUseCase.ExecuteAsync`, para toda mensagem processada — falha aqui é best-effort (logada, nunca derruba o request ao cliente), com timeout próprio de 5s.

### Mapa de portas — resumo

| Serviço | Porta (dev local, seção 3) | Porta host (`docker compose up -d`) | Downstream que chama |
|---|---|---|---|
| whatsapp-bff | `5153` | `5153` | Kafka (`9092`/`29092`, tópico `channel.webhook.received`) → consumido pelo próprio processo → Orchestrator |
| conversation-orchestrator | `8000` | **`5268`** | AgentRuntime (`8100`), ChannelBff (`5153`), HandoffService (`8200`)* — cliente do AuditService existe mas nunca é chamado (ver nota abaixo) |
| agent-runtime-renegotiation | `8100` | `8100` | OpenAI (externo, real), ToolService MCP (`8400`), KnowledgeService (`8500`) |
| tool-service-renegotiation | `8400` | `8400` | RenegotiationService (`9400` em dev local / `5266` em container) |
| renegotiation-service | `9400` | **`5266`** | ClientApi (`9401`), EligibilityApi (`9402`), ContractingApi (`9403`), FormalizationApi (`9404`) — todas servidas pelo `core-bancario-mock` (seção 3.0) |
| conversation-memory-service | `8600` | `8600` | Redis (`6379`), MongoDB (`27017`) — nenhum outro serviço o chama ainda |
| knowledge-service | `8500` | `8500` | OpenSearch (`9200`), OpenAI (externo, real, embeddings) — já é chamado de verdade por `agent-runtime-renegotiation` |
| conversation-audit-service | `8300` | `8300` | PostgreSQL (`5432`) — já é chamado de verdade pelo `conversation-orchestrator` (`AuditServiceClient`, ao fim de `IngestMessageUseCase.ExecuteAsync`) |

`*` = dependência **assumida**, ainda não implementada neste workspace. Erros de indisponibilidade nesses pontos (502, handoff automático, timeouts) são o comportamento esperado e documentado em cada change arquivada (`openspec/changes/archive/`) — todo serviço foi construído para degradar graciosamente (nunca derrubar o processo) quando esses downstream não respondem. As 4 APIs do Core Bancário já têm mock (seção 3.0). `knowledge-service` deixou de ser uma dependência assumida do Agent Runtime — é um serviço real agora, e o mesmo vale agora para `conversation-audit-service` em relação ao Orchestrator.

> **Validado em 2026-07-13** ([relatório](validation/2026-07-13-e2e-journey.md)): as portas host de `conversation-orchestrator` (`5268`) e `renegotiation-service` (`5266`) no modo `docker compose up -d` (hardcoded em `docker-compose.yml`, service-a-service sempre usa a rede interna do Docker em `:8080`) não eram documentadas em lugar nenhum — só a porta de dev local (`8000`/`9400`) aparecia aqui e no restante dos docs. Quem sobe o stack inteiro via `docker compose up -d` (o fluxo descrito primeiro no `README.md`) e tenta reproduzir os comandos da seção 4 contra `:8000`/`:9400` recebe conexão recusada. Além disso, a chamada ao `AuditService` a partir do Orchestrator estava **comentada no código** (`Application/UseCases/IngestMessageUseCase.cs`) — nunca era executada, então não havia "warning engolido" nem chamada real ao `audit-service-mock`, mesmo com o mock no ar. Detalhe em [`docs/services/conversation-orchestrator.md`](services/conversation-orchestrator.md#dependências-síncronas).
>
> **Atualizado em 2026-07-18**: a chamada foi descomentada e repontada para o `conversation-audit-service` real (seção 3.9) — o gap descrito acima não existe mais.

`whatsapp-bff` é o único serviço que depende do Kafka da infraestrutura (seção 2) para funcionar, e não só para publicar eventos de auditoria: sem Kafka no ar, o webhook responde `503` (não aceita a entrega) em vez de `200`.

> Esta tabela é um resumo operacional para subir o ambiente. A referência canônica de portas, tópicos Kafka e datastores — mantida separadamente para não duplicar e divergir desta — é [`docs/contracts/services-map.md`](contracts/services-map.md) e [`docs/contracts/kafka-events.md`](contracts/kafka-events.md). Detalhe de cada serviço (APIs, regras de negócio, eventos) em [`docs/services/`](services/).

### Tracing distribuído (Jaeger)

Os 8 serviços de aplicação exportam spans via OTLP para o Jaeger (seção 2, porta `16686`), formando um único trace por requisição de ponta a ponta (webhook → BFF → Orchestrator → Agent Runtime → Tool Service MCP → Renegotiation Service). `agent-runtime-renegotiation` já chama `knowledge-service` de verdade, então `GET /search` **participa** desse trace de ponta a ponta; o mesmo agora vale para `conversation-audit-service` (`conversation-orchestrator` já exporta `AddHttpClientInstrumentation()`, então a chamada a `POST /journey-events` carrega o contexto de trace). `conversation-memory-service` também exporta, mas ainda não participa — nada o chama (ver seção 3.7). Cada serviço aponta pro endpoint OTLP por uma variável própria:

| Serviço | Variável | Default local (`dotnet run`/`uvicorn`) |
|---|---|---|
| whatsapp-bff, conversation-orchestrator, renegotiation-service, conversation-audit-service | `Otel:OtlpEndpoint` (appsettings) / `Otel__OtlpEndpoint` (env) | `http://localhost:4317` |
| agent-runtime-renegotiation, tool-service-renegotiation, conversation-memory-service, knowledge-service | `OTEL_OTLP_ENDPOINT` | `http://localhost:4317` |

No `docker-compose.yml` todos apontam pra `http://jaeger:4317`. O SDK Strands Agents já vem com instrumentação própria (spans `chat`, `execute_tool`, `execute_event_loop_cycle`, `invoke_agent`) — só de registrar o `TracerProvider` no `agent-runtime-renegotiation`, esses spans já aparecem no trace, sem configuração adicional. O exportador OTLP nunca bloqueia o request se o Jaeger estiver fora do ar (falha silenciosamente, mesma filosofia catch-log-continue do resto da plataforma).

O mock (`core-bancario-mock`) não tem instrumentação — é um test double simples, sem latência real para decompor.

---

## 4. Smoke test end-to-end

Com a infra e os 5 serviços no ar (seções 2 e 3):

```bash
# 1. Handshake de verificação do webhook (whatsapp-bff)
curl "http://localhost:5153/webhooks/whatsapp?hub.mode=subscribe&hub.verify_token=<VerifyToken configurado>&hub.challenge=teste123"
# Esperado: 200 OK, corpo "teste123"

# 2. Mensagem simulada chegando no Orchestrator diretamente
curl -X POST http://localhost:8000/messages \
  -H "Content-Type: application/json" \
  -d '{"MessageId":"wamid.smoke-1","From":"5511999990000","ConversationId":"5511999990000","MessageType":"Text","Text":"Ola"}'
# Esperado: 202 Accepted (mesmo com Agent Runtime/downstream indisponíveis)
# MessageId, From e ConversationId são obrigatórios (400 Bad Request sem eles)

# 3. MCP Tool Service: listar ferramentas
python -c "
import asyncio
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

async def main():
    async with streamable_http_client('http://localhost:8400/mcp') as (r, w, _):
        async with ClientSession(r, w) as s:
            await s.initialize()
            print([t.name for t in (await s.list_tools()).tools])

asyncio.run(main())
"
# Esperado: lista com as 7 tools (consultar_cliente, consultar_contratos, ...)

# 4. Renegotiation Service (com o mock do Core Bancário no ar — seção 3.0)
curl "http://localhost:9400/contracts/contract-1/eligibility"
# Esperado: 200 OK, {"eligible":true,"reason":null}
# Sem o mock no ar: 502 Bad Gateway — comportamento correto, não é bug

# 5. Audit Service (seção 3.9)
curl -X POST http://localhost:8300/journey-events \
  -H "Content-Type: application/json" \
  -d '{"conversationId":"5511999990000","intent":null,"outcome":"handoff","timestamp":"2026-01-01T00:00:00Z"}'
# Esperado: 202 Accepted, e uma linha nova em ops.audit_events (ver seção 3.9)

# 6. Tracing distribuído: confirma que os 5 serviços exportaram spans pro Jaeger
curl -s http://localhost:16686/api/services
# Esperado: array incluindo whatsapp-bff, conversation-orchestrator,
# agent-runtime-renegotiation, tool-service-renegotiation, renegotiation-service
```

### Verificando a durabilidade do webhook via Kafka

Um webhook assinado de verdade (não o `curl` direto ao Orchestrator do passo 2 acima) passa pelo tópico `channel.webhook.received` antes de chegar ao Orchestrator. Para conferir que a publicação está acontecendo:

```bash
# Escuta o tópico bruto enquanto uma mensagem assinada é enviada em outro terminal
MSYS_NO_PATHCONV=1 docker exec conversational-ai-kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic channel.webhook.received --from-beginning
```

Com o `whatsapp-bff` no ar, envie um webhook assinado (o segredo é o `WhatsApp:AppSecret` do `appsettings.Development.json`):

```bash
BODY='{"object":"whatsapp_business_account","entry":[{"id":"e1","changes":[{"field":"messages","value":{"messages":[{"id":"wamid.smoke-1","from":"5511999990000","timestamp":"1700000000","type":"text","text":{"body":"Ola"}}]}}]}]}'
SIG=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "<AppSecret configurado>" | sed 's/^.* //')
curl -X POST http://localhost:5153/webhooks/whatsapp \
  -H "Content-Type: application/json" -H "X-Hub-Signature-256: sha256=$SIG" -d "$BODY"
# Esperado: 200 OK, e o payload aparece no consumer do tópico acima
```

Se o `conversation-orchestrator` estiver fora do ar nesse momento, o log do `whatsapp-bff` vai mostrar `Forward to Orchestrator failed ... retrying the same offset` em loop a cada ~2s — é o comportamento esperado (backpressure), não um bug.

---

## 5. Comandos úteis

```bash
# Ver logs de um container
docker logs -f conversational-ai-kafka

# Parar tudo (mantém volumes/dados)
docker compose stop

# Subir de novo
docker compose start

# Derrubar tudo, mantendo dados
docker compose down

# Derrubar tudo e apagar dados (reset completo)
docker compose down -v
```

---

## 6. Troubleshooting

### `bitnami/kafka:3.7`: manifest not found
A Bitnami removeu as tags gratuitas do Docker Hub em 2025. O `docker-compose.yml` já foi migrado para a imagem oficial `apache/kafka:3.9.2`, que usa variáveis `KAFKA_*` (sem prefixo `CFG_`) e exige `CLUSTER_ID` explícito. Se precisar regenerar um `CLUSTER_ID` novo:

```bash
python -c "import uuid, base64; print(base64.urlsafe_b64encode(uuid.uuid4().bytes).decode().rstrip('='))"
```

### Grafana não sobe / porta 3000 em uso
No Windows, a porta 3000 pode estar no range de portas excluídas (reservado pelo Hyper-V/WinNAT). Verifique com:

```powershell
netsh interface ipv4 show excludedportrange protocol=tcp
```

Se `3000` aparecer na lista, mantenha o mapeamento atual (`3001:3000` no compose) ou escolha outra porta livre.

### MongoDB Compass (ou outro client) conecta mas mostra dados/versão errados
Sintoma típico no Compass: `Server at localhost:27017 reports maximum wire version 7, but this version of the Node.js Driver requires at least 8 (MongoDB 4.2)` — bem mais antigo que a versão real (`mongo:7`, MongoDB 7.x) rodando no container. Isso acontece quando a máquina também tem um `mongod.exe` nativo instalado como serviço do Windows, escutando em `127.0.0.1:27017`; o Windows roteia conexões a `localhost`/`127.0.0.1` para esse bind mais específico em vez do `0.0.0.0:27017` do container Docker. Confirme com:

```bash
netstat -ano | grep ":27017"
tasklist //FI "PID eq <pid do listener em 127.0.0.1>"
```

Se aparecer `mongod.exe` (não um processo do Docker), é esse o conflito. O `docker-compose.yml` deste repositório já mapeia o Mongo do container para a porta host `27018` (não `27017`) justamente por causa disso — conecte o Compass em `localhost:27018`, não `27017`.

### `conversation-audit-service` (ou qualquer escrita no Postgres) ocasionalmente muito lento ou dá `503`
Em Docker Desktop no Windows, o disco virtualizado usado pelo volume do Postgres pode ter picos de I/O bem lentos — um `checkpoint` que deveria levar milissegundos já foi observado levando **~51s** no log do container (`docker logs conversational-ai-postgres`, procure por `checkpoint complete: ... total=`). Quando isso acontece durante um `INSERT`, o `conversation-audit-service` responde `503` (ver seção 3.9) e, do lado do `conversation-orchestrator`, o `AuditServiceClient` estoura seu timeout de 5s (`SideEffectCallTimeout`) e loga "Failed to record journey audit event" — ambos são o comportamento *correto* de degradação, não um bug. Fora desses picos, uma chamada de auditoria completa normalmente em menos de 2s. Se isso for frequente na sua máquina, verifique se o antivírus está escaneando o disco virtual do Docker Desktop (VHDX/WSL2) em tempo real, e considere excluí-lo da varredura.

### `docker exec`/`docker run` no Git Bash: "not found" em caminhos como `/opt/kafka/bin/...`
O Git Bash (MSYS) converte automaticamente argumentos que parecem paths Unix em paths Windows. Prefixe o comando com `MSYS_NO_PATHCONV=1`:

```bash
MSYS_NO_PATHCONV=1 docker exec conversational-ai-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
```

### Scripts de init do Postgres/Mongo não rodaram
Só executam com o volume **vazio** na primeira subida. Ver seção 2 → "Inicialização dos bancos" para recriar os volumes.

### Serviço retorna erro/handoff automático apontando para um downstream "unavailable"
Verifique a tabela da seção 3 ("Mapa de portas"): se o downstream está marcado com `*`, ele é uma dependência **assumida** e ainda não implementada — o comportamento correto de cada serviço é degradar (502, handoff, fallback), nunca cair. Não é um bug a menos que o serviço em si trave ou pare de responder.

### Webhook aceito (`200 OK`) mas a mensagem nunca chega no Orchestrator
Desde que a fila em memória do `whatsapp-bff` foi substituída pelo Kafka (seção 3.6), isso normalmente significa que o `conversation-orchestrator` está fora do ar (ou inacessível) e o `KafkaWebhookConsumerService` está retentando a mesma mensagem em loop (por design — ver seção 3.6). Confira o log do `whatsapp-bff` por `Forward to Orchestrator failed ... retrying the same offset`; suba o Orchestrator (seção 3.5) e o processamento retoma sozinho a partir da mesma mensagem, sem precisar reenviar o webhook. Se o webhook responder `503` em vez de `200`, o problema é o Kafka em si (broker fora do ar) — confira `docker compose ps` (seção 2).

### Agent Runtime responde `200 OK` mas com `HandoffReason: "agent_runtime_unavailable"`
Isso **não** é o Orchestrator falhando em alcançar o Agent Runtime (esse caso não teria resposta `200` nenhuma) — é o próprio `agent-runtime-renegotiation` respondendo normalmente, mas caindo no fallback de `invoke_agent` porque a chamada à OpenAI falhou (`OPENAI_API_KEY` ausente/inválida, por exemplo). Ver seção 3.3 para subir com `MOCK_AGENT_ENABLED=true` e evitar depender da OpenAI localmente.

---

## 7. O que ainda não existe

- **Handoff Service**: container/serviço não implementado neste workspace; PostgreSQL já tem o schema pronto para quando for construído. (**Memory Service** foi implementado — `conversation-memory-service`, seção 3.7 — mas ainda não é chamado por nenhum outro serviço; ver nota na seção 3.7. **Knowledge Service** também foi implementado — `knowledge-service`, seção 3.8 — e já é chamado de verdade por `agent-runtime-renegotiation`.)
- **Core Bancário real** (Client/Eligibility/Contracting/Formalization APIs): sistema externo de fato, fora do escopo — existe apenas um **mock** local (`core-bancario-mock/`, seção 3.0) com dados fake, para permitir testar o fluxo completo sem `502`.
- **Audit Service real**: implementado e integrado — `conversation-audit-service` (seção 3.9), que persiste de verdade em `ops.audit_events` (PostgreSQL) — e já é chamado de verdade pelo `conversation-orchestrator` ao fim de cada `IngestMessageUseCase.ExecuteAsync`. O `audit-service-mock` foi removido.
- Uma `OPENAI_API_KEY` real, se você ainda não tiver uma configurada (necessária para o Agent Runtime raciocinar de verdade em vez de cair no fallback de handoff) — use `MOCK_AGENT_ENABLED=true` (seção 3.3) enquanto isso.

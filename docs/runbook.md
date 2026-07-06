# Runbook — Ambiente Local

Guia operacional para subir, verificar e depurar o ambiente local completo da Plataforma de IA Conversacional: infraestrutura (Docker Compose) + os 5 serviços de aplicação implementados até o momento + o mock do Core Bancário.

Repositórios (todos irmãos, na raiz do workspace `whatsapp/`):

| Serviço | Pasta | Stack | Container? |
|---|---|---|---|
| Channel BFF | `whatsapp-bff/` | .NET 8 | não |
| Conversation Orchestrator | `conversation-orchestrator/` | .NET 8 | não |
| Agent Runtime | `agent-runtime-renegotiation/` | Python / Strands Agents / FastAPI | não |
| Tool Service (MCP) | `tool-service-renegotiation/` | Python / MCP (FastMCP) | não |
| Renegotiation Service | `renegotiation-service/` | .NET 8 | não |
| Core Bancário (mock) | `core-bancario-mock/` | .NET 8 | não |
| Infraestrutura | `conversational-ai-demo-arch/` | Docker Compose | sim |

Nenhum dos serviços de aplicação tem Dockerfile ainda — todos rodam localmente via `dotnet run` / `uvicorn`, apontando para a infraestrutura em containers.

---

## 1. Pré-requisitos

- Docker Desktop (Docker Engine 20.10+, Compose v2) rodando.
- .NET 8 SDK (`dotnet --version`).
- Python 3.12 (cada serviço Python tem seu próprio `.venv` já criado em `agent-runtime-renegotiation/.venv` e `tool-service-renegotiation/.venv`). **Não use Python 3.14**: o debugger do Visual Studio 2022 (PTVS/debugpy) ainda não suporta as mudanças internas do módulo `threading` no 3.14 (`AttributeError: '_MainThread' object has no attribute '_handle'` ao encerrar o processo) — [issue conhecida](https://github.com/microsoft/debugpy/issues/1893), corrigida upstream mas ainda não lançada pelo VS.
- Portas livres no host: `5432, 6379, 9092, 29092, 9090, 16686, 27017, 3001, 3100, 4317, 4318, 5153, 8000, 8100, 8400, 9400, 9401, 9402, 9403, 9404`.

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
| MongoDB | `27017` | histórico de mensagens, memória conversacional, LLM runs, tool calls, RAG |
| Redis | `6379` | cache / sessão |
| Kafka | `9092` (interno/containers), `29092` (host) | event streaming |
| Jaeger UI | `16686` | tracing (OTLP em `4317`/`4318`) |
| Prometheus | `9090` | métricas |
| Grafana | **`3001`** | dashboards (login `admin`/`admin`) |
| Loki | `3100` | logs |

> **Grafana está em `3001`, não `3000`.** A porta 3000 está no range de portas excluídas do Windows nesta máquina (`netsh interface ipv4 show excludedportrange protocol=tcp` — reservada pelo Hyper-V/WinNAT). Ver seção de Troubleshooting.

### Credenciais dos bancos

| Banco | Usuário | Senha | Database |
|---|---|---|---|
| PostgreSQL | `postgres` | `postgres` | `conversational_ai` |
| MongoDB (root) | `admin` | `admin` | authSource `admin` |
| MongoDB (app) | `conversational_ai_app` | `conversational_ai_app` | `conversational_ai`, role `readWrite` |

```bash
psql -h localhost -U postgres -d conversational_ai
mongosh "mongodb://admin:admin@localhost:27017/conversational_ai?authSource=admin"
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

### 3.2 Tool Service / MCP (Python) — porta `8400`

```bash
cd tool-service-renegotiation
source .venv/Scripts/activate   # Windows: .venv\Scripts\activate
python -m app.main
```

Serve MCP via streamable-HTTP em `http://localhost:8400/mcp`. Chama `RenegotiationService` em `http://localhost:9400` (seção 3.1).

### 3.3 Agent Runtime (Python/Strands) — porta `8100`

```bash
cd agent-runtime-renegotiation
source .venv/Scripts/activate
uvicorn app.main:app --host 127.0.0.1 --port 8100
```

Expõe `POST /process`. Chama Bedrock (precisa de credenciais AWS reais — sem elas, cai no fallback de handoff), o Tool Service via MCP (`:8400`, seção 3.2) e a `KnowledgeService` assumida (`:8500`, inexistente).

### 3.4 Conversation Orchestrator (.NET) — porta `8000`

```bash
cd conversation-orchestrator
dotnet run --urls http://localhost:8000
```

Expõe `POST /messages`. Chama `AgentRuntime` (`:8100`, seção 3.3), `ChannelBff` (`:5153`, seção 3.5), e as ainda-inexistentes `HandoffService` (`:8200`) e `AuditService` (`:8300`).

### 3.5 Channel BFF (.NET) — porta `5153` (padrão do `dotnet run`)

```bash
cd whatsapp-bff
dotnet run
```

Expõe `POST /webhooks/whatsapp` (webhook do WhatsApp) e `POST /internal/messages` (callback de resposta).

A entrega ao Orchestrator **não** é mais uma chamada síncrona dentro do próprio request do webhook. O fluxo real é:

1. `POST /webhooks/whatsapp` valida a assinatura HMAC, deduplica por `messageId` e publica o payload bruto no tópico Kafka `channel.webhook.received` (chave de partição = telefone do cliente). Só devolve `200 OK` **depois** que essa publicação é confirmada — se o Kafka estiver fora do ar, devolve `503` para que a Meta reentregue.
2. Um `BackgroundService` interno ao mesmo processo (`KafkaWebhookConsumerService`, grupo de consumidor `whatsapp-bff-webhook-consumer`) lê esse tópico e é quem de fato chama `POST {Orchestrator:BaseUrl}/messages` (`:8000`, seção 3.4).
3. O commit do offset só acontece se **todas** as mensagens daquela entrega forem encaminhadas com sucesso. Se o Orchestrator estiver fora do ar, o consumer dá `Seek` de volta para o mesmo offset e tenta de novo a cada ~2s — ou seja, uma indisponibilidade do Orchestrator trava o processamento desse tópico (backpressure), em vez de perder a mensagem.

Kafka substituiu o que antes era uma fila em memória entre o webhook e o Orchestrator: agora a durabilidade sobrevive a um restart/crash do `whatsapp-bff`.

> Para testar o handshake de verificação do webhook, defina `WhatsApp:VerifyToken` em `appsettings.Development.json` (ou variável de ambiente) e rode com `ASPNETCORE_ENVIRONMENT=Development`.

### Mapa de portas — resumo

| Serviço | Porta | Downstream que chama |
|---|---|---|
| whatsapp-bff | `5153` | Kafka (`9092`/`29092`, tópico `channel.webhook.received`) → consumido pelo próprio processo → Orchestrator (`8000`) |
| conversation-orchestrator | `8000` | AgentRuntime (`8100`), ChannelBff (`5153`), HandoffService (`8200`)*, AuditService (`8300`)* |
| agent-runtime-renegotiation | `8100` | Bedrock (AWS)*, ToolService MCP (`8400`), KnowledgeService (`8500`)* |
| tool-service-renegotiation | `8400` | RenegotiationService (`9400`) |
| renegotiation-service | `9400` | ClientApi (`9401`), EligibilityApi (`9402`), ContractingApi (`9403`), FormalizationApi (`9404`) — todas servidas pelo `core-bancario-mock` (seção 3.0) |

`*` = dependência **assumida**, ainda não implementada neste workspace. Erros de indisponibilidade nesses pontos (502, handoff automático, timeouts) são o comportamento esperado e documentado em cada change arquivada (`openspec/changes/archive/`) — todo serviço foi construído para degradar graciosamente (nunca derrubar o processo) quando esses downstream não respondem. As 4 APIs do Core Bancário já têm mock (seção 3.0) — sem ele no ar, o comportamento de degradação (502) continua sendo o esperado.

`whatsapp-bff` é o único serviço que depende do Kafka da infraestrutura (seção 2) para funcionar, e não só para publicar eventos de auditoria: sem Kafka no ar, o webhook responde `503` (não aceita a entrega) em vez de `200`.

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
  -d '{"ConversationId":"5511999990000","MessageType":"Text","Text":"Ola"}'
# Esperado: 202 Accepted (mesmo com Agent Runtime/downstream indisponíveis)

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
Desde que a fila em memória do `whatsapp-bff` foi substituída pelo Kafka (seção 3.5), isso normalmente significa que o `conversation-orchestrator` está fora do ar (ou inacessível) e o `KafkaWebhookConsumerService` está retentando a mesma mensagem em loop (por design — ver seção 3.5). Confira o log do `whatsapp-bff` por `Forward to Orchestrator failed ... retrying the same offset`; suba o Orchestrator (seção 3.4) e o processamento retoma sozinho a partir da mesma mensagem, sem precisar reenviar o webhook. Se o webhook responder `503` em vez de `200`, o problema é o Kafka em si (broker fora do ar) — confira `docker compose ps` (seção 2).

---

## 7. O que ainda não existe

- **Memory Service**, **Knowledge Service**, **Audit Service**, **Handoff Service**: containers/serviços não implementados neste workspace; PostgreSQL e MongoDB já têm o schema pronto para quando forem construídos.
- **Core Bancário real** (Client/Eligibility/Contracting/Formalization APIs): sistema externo de fato, fora do escopo — existe apenas um **mock** local (`core-bancario-mock/`, seção 3.0) com dados fake, para permitir testar o fluxo completo sem `502`.
- **Dockerfiles** para os serviços de aplicação — hoje só rodam via `dotnet run`/`uvicorn` local.
- Credenciais reais da AWS Bedrock (necessárias para o Agent Runtime raciocinar de verdade em vez de cair no fallback de handoff).

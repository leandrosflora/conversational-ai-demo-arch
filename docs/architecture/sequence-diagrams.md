# Diagramas de sequência — estado implementado P1

Os diagramas abaixo descrevem somente código implementado. A arquitetura-alvo está separada em `C4/c4-container-target.puml`.

## 1. Processamento normal

```plantuml
@startuml
hide footbox
autonumber

actor Cliente
participant "WhatsApp Cloud API" as Meta
participant "whatsapp-bff" as BFF
queue "Kafka\nchannel.webhook.received" as Kafka
participant "conversation-orchestrator" as Orch
database "PostgreSQL\nInbox" as Inbox
participant "conversation-memory-service" as Memory
database Redis
database MongoDB
participant "agent-runtime-renegotiation" as Agent
participant "knowledge-service" as Knowledge
database OpenSearch
participant "tool-service-renegotiation" as Tools
participant "renegotiation-service" as Reneg
participant "Core Bancário Mock" as Core
participant "conversation-audit-service" as Audit
participant "conversation-handoff-service" as Handoff

Cliente -> Meta: mensagem
Meta -> BFF: POST /webhooks/whatsapp\nX-Hub-Signature-256
BFF -> BFF: valida HMAC e reserva messageId
BFF ->> Kafka: payload bruto\ntraceparent/tracestate
Kafka --> BFF: confirmação de persistência
BFF -> BFF: marca dedupe como completed
BFF --> Meta: 200 OK

Kafka ->> BFF: entrega ao consumer\ncontexto W3C extraído
activate BFF
BFF -> Orch: POST /messages\nJWT aud=conversation-orchestrator\nX-Tenant-Id
activate Orch
Orch -> Inbox: acquire(messageId, lease)
Inbox --> Orch: acquired

Orch -> Memory: POST histórico usuário\nJWT + X-Tenant-Id
Memory -> MongoDB: insert idempotente por externalMessageId
Orch -> Memory: GET sessão\nJWT + X-Tenant-Id
Memory -> Redis: GET tenant:{tenant}:session:{conversation}
Memory --> Orch: estado da jornada

Orch -> Agent: POST /process\nJWT + X-Tenant-Id + TenantId no payload
activate Agent
Agent -> Knowledge: GET /search\nJWT + X-Tenant-Id
Knowledge -> OpenSearch: k-NN no índice faq_chunks-{tenant}
OpenSearch --> Knowledge: chunks do tenant
Knowledge --> Agent: contexto RAG

Agent -> Tools: MCP streamable HTTP\nJWT + X-Tenant-Id
activate Tools
Tools -> Reneg: capacidade de domínio\nJWT + X-Tenant-Id
Reneg -> Core: API mock\nJWT enviado + X-Tenant-Id\n(mock ainda não valida)
Core --> Reneg: resposta
Reneg --> Tools: resultado
Tools ->> Kafka: tool.executed\ntrace + tenant, sem argumentos sensíveis
Tools --> Agent: resultado da tool
deactivate Tools

Agent ->> Kafka: agent.events\ntrace + tenant
Agent --> Orch: decisão estruturada
deactivate Agent

Orch ->> Kafka: intent.detected / state_changed\ntrace + tenant
Orch -> Memory: PUT sessão + POST resposta\nJWT + X-Tenant-Id
Memory -> Redis: SET sessão tenant-scoped
Memory -> MongoDB: append resposta

alt RequiresHandoff = true
  Orch -> Handoff: POST /handoffs\nJWT + X-Tenant-Id\nIdempotency-Key=handoff:{messageId}
  Handoff -> PostgreSQL: INSERT ON CONFLICT DO NOTHING
else resposta automática
  Orch -> BFF: POST /internal/messages\nJWT + X-Tenant-Id
  BFF -> Meta: envia resposta
  Meta -> Cliente: entrega resposta
end

Orch -> Audit: POST /journey-events\nJWT + X-Tenant-Id\nIdempotency-Key=audit:{messageId}
Audit -> PostgreSQL: INSERT tenant real\nON CONFLICT DO NOTHING
Orch -> Inbox: status=completed
Orch --> BFF: 202 Accepted
deactivate Orch
BFF -> Kafka: commit offset
deactivate BFF
@enduml
```

## 2. Retry transitório e DLQ

```plantuml
@startuml
hide footbox
autonumber

queue "channel.webhook.received" as Input
participant "KafkaWebhookConsumerService" as Consumer
participant "conversation-orchestrator" as Orch
queue "channel.webhook.received.retry" as Retry
queue "channel.webhook.received.dlq" as DLQ

Input ->> Consumer: registro + traceparent
Consumer -> Consumer: extrai trace e lê x-delivery-attempt

alt JSON inválido ou payload nulo
  Consumer ->> DLQ: payload original + reason/source metadata
  DLQ --> Consumer: publish confirmado
  Consumer -> Input: commit offset original
else falha transitória
  Consumer -> Orch: POST /messages
  Orch --> Consumer: erro/409/indisponível
  alt tentativa < MaxDeliveryAttempts
    Consumer ->> Retry: payload + tentativa incrementada
    Retry --> Consumer: publish confirmado
    Consumer -> Input: commit offset original
    Retry ->> Consumer: nova entrega
  else tentativas esgotadas
    Consumer ->> DLQ: payload + attempts + reason
    DLQ --> Consumer: publish confirmado
    Consumer -> Retry: commit offset
  end
else sucesso
  Consumer -> Orch: POST /messages
  Orch --> Consumer: 202
  Consumer -> Input: commit offset
end

note right of Consumer
Se publicar retry/DLQ falhar,
o offset original não é commitado
e o consumer faz Seek/replay.
end note
@enduml
```

## 3. Garantias e limites

| Aspecto | Garantia implementada |
|---|---|
| Entrada WhatsApp | ACK somente depois do Kafka confirmar |
| Dedupe BFF | `pending` antes do Kafka; `completed` depois da confirmação |
| Dedupe Orchestrator | Inbox PostgreSQL com lease e estados |
| Side effects | Audit/Handoff com `Idempotency-Key` |
| Kafka poison | DLQ com payload e metadados de origem |
| Trace Kafka | `traceparent`/`tracestate` propagados e extraídos |
| Tenant | JWT identifica workload; `X-Tenant-Id` acompanha todas as chamadas |
| Sessão | chave Redis inclui tenant |
| RAG | índice físico OpenSearch por tenant |

Limites atuais:

- Core mock recebe JWT, mas não o valida.
- Handoff persiste o pedido, mas não transfere para uma plataforma humana real.
- Eventos de observabilidade sem consumer funcional continuam sendo trilha assíncrona, não integração de negócio.

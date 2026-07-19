# Diagramas de sequência — estado implementado P0/P1

Os diagramas abaixo descrevem somente o código implementado. A arquitetura-alvo permanece separada em `C4/c4-container-target.puml`.

## 1. Aceite da mensagem e persistência transacional

```plantuml
@startuml
hide footbox
autonumber

actor Cliente
participant "WhatsApp Cloud API" as Meta
participant "whatsapp-bff" as BFF
queue "Kafka\nchannel.webhook.received" as Kafka
participant "conversation-orchestrator" as Orch
database "PostgreSQL\nInbox + State + Outbox" as Pg
participant "agent-runtime-renegotiation" as Agent
participant "tool-service-renegotiation" as Tools
participant "renegotiation-service" as Reneg
participant "Core Bancário Mock" as Core

Cliente -> Meta: mensagem
Meta -> BFF: POST /webhooks/whatsapp\nX-Hub-Signature-256
BFF -> BFF: valida HMAC e reserva messageId
BFF ->> Kafka: payload bruto + traceparent
Kafka --> BFF: confirmação de persistência
BFF -> BFF: marca dedupe de entrada como completed
BFF --> Meta: 200 OK

Kafka ->> BFF: entrega ao consumer
BFF -> Orch: POST /messages\nJWT tenant_id + X-Tenant-Id
Orch -> Pg: acquire Inbox + lease da conversa
Pg --> Orch: checkpoint(stage, version, lastReceivedAt)

alt mensagem atrasada
  Orch -> Pg: Inbox=completed\nreason=late_message\nlibera lease
  Orch --> BFF: 202
else mensagem atual
  Orch -> Agent: POST /process\nmessageId + stage + version\nconfirmationMessageId quando explícita
  activate Agent

  Agent -> Tools: MCP + JWT tool_execution\ncontexto assinado
  activate Tools
  Tools -> Tools: valida caller, stage, version\ne evidência de confirmação

  alt operação permitida
    Tools -> Reneg: JWT governed_tool\npolicy_id + Idempotency-Key
    Reneg -> Reneg: valida novamente tool/stage/evidência
    Reneg -> Core: operação autorizada
    Core --> Reneg: resposta
    Reneg --> Tools: resposta
  else policy negada
    Tools --> Agent: erro de autorização
  end
  deactivate Tools
  Agent --> Orch: decisão estruturada
  deactivate Agent

  Orch -> Orch: aplica máquina de estados
  Orch -> Pg: BEGIN\nUPDATE state WHERE version esperada\nINSERT efeitos na Outbox\nUPDATE Inbox=completed\nCOMMIT
  Pg --> Orch: efeitos duravelmente registrados
  Orch --> BFF: 202 Accepted
end

BFF -> Kafka: commit offset
@enduml
```

## 2. Dispatcher da Outbox

```plantuml
@startuml
hide footbox
autonumber

participant "OutboxDispatcher" as Dispatcher
database "PostgreSQL\norchestrator_outbox" as Outbox
participant "conversation-memory-service" as Memory
participant "conversation-audit-service" as Audit
participant "conversation-handoff-service" as Handoff
participant "whatsapp-bff" as BFF
queue Kafka
participant "WhatsApp Cloud API" as Meta

Dispatcher -> Outbox: claim batch\nFOR UPDATE SKIP LOCKED
Outbox --> Dispatcher: somente menor journey_version pendente\npor conversa

loop cada efeito
  alt memory projection
    Dispatcher -> Memory: JWT tenant + Idempotency
    Memory --> Dispatcher: sucesso/duplicado
  else audit
    Dispatcher -> Audit: Idempotency-Key tenant-scoped
    Audit --> Dispatcher: sucesso/duplicado
  else handoff
    Dispatcher -> Handoff: Idempotency-Key tenant-scoped
    Handoff --> Dispatcher: sucesso/duplicado
  else resposta ao canal
    Dispatcher -> BFF: Idempotency-Key
    BFF -> BFF: SET NX pending no Redis
    BFF -> Meta: envia mensagem
    Meta --> BFF: messageId
    BFF -> BFF: completed:messageId no Redis
    BFF --> Dispatcher: 202 + messageId
  else evento
    Dispatcher ->> Kafka: intent/state + trace + tenant
  end

  alt sucesso
    Dispatcher -> Outbox: status=published
  else falha
    Dispatcher -> Outbox: status=failed\nnext_attempt_at com backoff
  end
end

note right of Outbox
Uma versão posterior da conversa
não é liberada enquanto existir
efeito não publicado de versão anterior.
end note
@enduml
```

## 3. Idempotência de simulação e confirmação

```plantuml
@startuml
hide footbox
autonumber

participant Agent
participant "Tool Service" as Tools
participant "Renegotiation Service" as Reneg
database "PostgreSQL\nrenegotiation_idempotency" as Idem
participant "Core Bancário Mock" as Core

Agent -> Tools: chama simular_proposta
Tools -> Tools: policy por stage\ngera chave determinística
Tools -> Reneg: POST simulation\nJWT governed_tool + Idempotency-Key
Reneg -> Reneg: valida policy_id == header
Reneg -> Idem: INSERT key/requestHash status=processing

alt chave nova
  Reneg -> Core: simulação uma vez\nIdempotency-Key propagada
  Core --> Reneg: resultado
  Reneg -> Idem: status=completed + response
  Reneg --> Tools: resultado
else chave concluída
  Idem --> Reneg: resposta persistida
  Reneg --> Tools: mesmo resultado sem Core
else mesma chave com outro request
  Reneg --> Tools: 409 conflict
else processing/failed ambíguo
  Reneg --> Tools: 409 in progress\nreconciliação administrativa
end

Agent -> Tools: chama confirmar_acordo
Tools -> Tools: exige ProposalSelected/ConfirmationPending\nconfirmationMessageId == messageId
Tools -> Reneg: JWT governed_tool + policy_id
Reneg -> Reneg: repete validação da evidência
Reneg -> Core: confirmação autorizada
@enduml
```

## 4. Retry de entrada e DLQ

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
  Consumer ->> DLQ: payload original + reason/source
  DLQ --> Consumer: publish confirmado
  Consumer -> Input: commit offset
else Orchestrator retorna 409/erro
  Consumer ->> Retry: payload + tentativa incrementada
  Retry --> Consumer: publish confirmado
  Consumer -> Input: commit offset original
  Retry ->> Consumer: nova entrega
else tentativas esgotadas
  Consumer ->> DLQ: payload + attempts + reason
  DLQ --> Consumer: publish confirmado
  Consumer -> Retry: commit offset
else 202
  Consumer -> Input: commit offset
end

note right of Consumer
Se publicar retry ou DLQ falhar,
o offset original não é commitado
e o consumer executa Seek/replay.
end note
@enduml
```

## 5. Garantias e limites

| Aspecto | Garantia implementada |
|---|---|
| Entrada WhatsApp | ACK somente depois de Kafka confirmar persistência |
| Conclusão do Inbox | Apenas após estado e efeitos serem gravados na mesma transação |
| Side effects | Outbox at-least-once + deduplicação no destino |
| Ordenação | lease por conversa, versão otimista, late-message detection e barrier na Outbox |
| Tenant | UUID canônico presente no header e em claim JWT assinada |
| Tools | allowlist por estágio e policy proof validada no Tool e no serviço de domínio |
| Simulação | resultado persistido por tenant/key/hash; replay sem Core |
| Confirmação | exige evidência assinada ligada à mensagem atual |
| Memória | unicidade `(tenantId, externalMessageId)` |
| Audit/Handoff | unicidade `(tenant_id, idempotency_key)` |

Limites atuais:

- o Core Bancário Mock não está disponível para implementação da validação de JWT e idempotência no último salto;
- por isso, simulações ambíguas falham fechadas e exigem reconciliação administrativa;
- Handoff ainda persiste o pedido, sem transferir para plataforma humana real;
- o HS256 compartilhado continua sendo solução de POC endurecida;
- build, migração em volume existente e E2E precisam ser executados antes do merge.

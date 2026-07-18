# Diagramas de sequência da jornada

Do gatilho de campanha até a consulta de débitos e elegibilidade: como uma mensagem do WhatsApp atravessa o `whatsapp-bff`, o `conversation-orchestrator`, o agente Strands/OpenAI, o servidor MCP e o Core Bancário mock.

## Legenda

| Notação | Significado |
|---|---|
| `->` | Chamada síncrona (HTTP ou MCP) |
| `-->` | Retorno / resposta a uma chamada síncrona |
| `->>` | Evento assíncrono / publicação Kafka |
| `activate` / `deactivate` | Janela de processamento interno |
| `note` | Observação — comportamento não óbvio a partir do código |
| `loop` / `alt` | Fragmento que se repete ou depende de uma condição |

**Conceitual** = descrito em [`business-context.md`](../context/business-context.md) / [C4 nível 1](c4-context.md), sem componente técnico implementado neste workspace.
**Implementado** = verificado no código e nas specs (endpoints, portas e tópicos reais); ver [`runbook.md`](../runbook.md) para subir o ambiente local.

---

## A · Entrada por campanha (conceitual)

Salesforce CRM → Data Lake → Automação de Campanha → Cliente → WhatsApp. Nenhum destes componentes existe como código neste workspace — é o gatilho de negócio que antecede o diagrama B.

```plantuml
@startuml
hide footbox
autonumber
skinparam sequenceMessageAlign center
skinparam responseMessageBelowArrow true

title A · Entrada por campanha (conceitual)

participant "Salesforce CRM" as SF
participant "Data Lake Corporativo" as DL
participant "Automação de Campanha" as Camp
actor Cliente
participant "WhatsApp BSP" as BSP
participant "Plataforma de IA Conversacional" as Plat

SF -> DL: Disponibiliza base de clientes elegíveis para renegociação
DL -> Camp: Base de campanha é consumida
Camp -> Cliente: Envia comunicação de ativação\nEmail, SMS, Instagram ou Facebook

note over Cliente
Cliente decide responder e é direcionado
ao WhatsApp oficial do banco.
end note

Cliente -> BSP: Inicia a conversa no WhatsApp oficial do banco
BSP -> Plat: Encaminha a mensagem inicial via webhook
Plat -> Plat: Inicia a jornada de identificação\ne consulta de débitos
Plat ->> DL: Eventos de jornada para auditoria/analytics\nconceitual, sem serviço implementado
@enduml
```

---

## B · Identificação do cliente & consulta de débitos/elegibilidade (implementado)

Verificado no código e nas specs OpenSpec. Portas conforme o [`runbook.md`](../runbook.md) — os valores em `launchSettings.json` do Visual Studio não são usados na execução real.

> A entrada via Kafka (`channel.webhook.received` → `KafkaWebhookConsumerService`) substituiu a antiga fila em memória entre o webhook e o Orchestrator: a durabilidade agora sobrevive a um restart/crash do `whatsapp-bff`, e uma indisponibilidade do Orchestrator vira retry com backpressure em vez de perda de mensagem.

```plantuml
@startuml
hide footbox
autonumber
skinparam sequenceMessageAlign center
skinparam responseMessageBelowArrow true

title B · Identificação do cliente e consulta de débitos/elegibilidade

actor Cliente
participant "WhatsApp BSP" as BSP
participant "whatsapp-bff" as BFF
queue Kafka
participant "conversation-orchestrator" as Orch
participant "agent-runtime-renegotiation" as Agent
participant "tool-service-renegotiation" as Tool
participant "renegotiation-service" as Reneg
participant "core-bancario-mock" as Core

Cliente -> BSP: Envia mensagem\ntexto ou resposta interativa
BSP -> BFF: POST /webhooks/whatsapp\nassinado com X-Hub-Signature-256
activate BFF
BFF -> BFF: Valida HMAC-SHA256\ne deduplica por messageId
BFF ->> Kafka: Publica channel.webhook.received\npayload bruto, chave = telefone
BFF --> BSP: 200 OK\n503 se Kafka recusar a publicação
deactivate BFF

note over BFF,Kafka
KafkaWebhookConsumerService
BackgroundService no mesmo processo
consome o tópico de forma assíncrona.
end note

Kafka ->> BFF: Entrega channel.webhook.received ao consumer
BFF -> Orch: POST /messages\nMessageId, From, ConversationId, Type, Text

note right of BFF
Commit do offset só ocorre se o forward tiver sucesso.
Se falhar, faz Seek de volta ao mesmo offset
e retenta a cada aproximadamente 2 segundos.
end note

activate Orch
Orch -> Orch: Cria ou recupera a sessão da conversa\nTTL 30 min, em memória
Orch -> Agent: POST /process\nConversationId, JourneyStage, LastIntent, Text
activate Agent
Agent -> Tool: MCP list_tools()\nstreamable-HTTP /mcp

loop Uma chamada MCP para cada dado que o agente precisa confirmar
    Agent -> Tool: call consultar_cliente(cpf)
    activate Tool
    Tool -> Reneg: GET /clients/{cpf}
    activate Reneg
    Reneg -> Core: ClientApi (:9401)
    activate Core
    Core --> Reneg: 200 OK · dados do cliente
    deactivate Core
    Reneg --> Tool: 200 OK\nmesmo se o cliente não for encontrado
    deactivate Reneg
    Tool ->> Kafka: tool.executed\nCPF mascarado
    Tool --> Agent: resultado consultar_cliente
    deactivate Tool

    Agent -> Tool: call consultar_contratos(clientId)
    activate Tool
    Tool -> Reneg: GET /clients/{clientId}/contracts
    activate Reneg
    Reneg --> Tool: 200 OK · contratos
    deactivate Reneg
    Tool ->> Kafka: tool.executed
    Tool --> Agent: resultado consultar_contratos
    deactivate Tool

    Agent -> Tool: call consultar_débitos(contractId)
    activate Tool
    Tool -> Reneg: GET /contracts/{contractId}/debts
    activate Reneg
    Reneg --> Tool: 200 OK · débitos em aberto
    deactivate Reneg
    Tool ->> Kafka: tool.executed
    Tool --> Agent: resultado consultar_débitos
    deactivate Tool

    Agent -> Tool: call validar_elegibilidade(contractId)
    activate Tool
    Tool -> Reneg: GET /contracts/{contractId}/eligibility
    activate Reneg
    Reneg -> Core: EligibilityApi (:9402)
    activate Core
    Core --> Reneg: 200 OK · eligible / reason
    deactivate Core
    Reneg --> Tool: 200 OK\n502 só se Core Bancário estiver inacessível
    deactivate Reneg
    Tool ->> Kafka: tool.executed
    Tool --> Agent: resultado validar_elegibilidade
    deactivate Tool
end

Agent ->> Kafka: agent.events\nintent, confidence, requires_handoff
Agent --> Orch: 200 OK\nIntent, Confidence, ReplyText, RequiresHandoff
deactivate Agent
Orch ->> Kafka: intent.detected + conversation.state_changed

alt RequiresHandoff = false
    Orch -> BFF: POST /internal/messages\nTo, Type text, Text replyText
    activate BFF
    BFF -> BSP: POST /{phone-number-id}/messages\nGraph API
    BSP -> Cliente: Entrega a resposta\ndébitos elegíveis apresentados
    deactivate BFF
end

deactivate Orch
@enduml
```

---

## Serviços, tópicos e lacunas conhecidas

| Serviço | Stack | Porta (dev) |
|---|---|---|
| whatsapp-bff | .NET 8 · Minimal API | `5153` |
| conversation-orchestrator | .NET 8 · Minimal API | `8000` |
| agent-runtime-renegotiation | Python · FastAPI · Strands + OpenAI | `8100` |
| tool-service-renegotiation | Python · MCP (FastMCP) | `8400` |
| renegotiation-service | .NET 8 · Minimal API | `9400` |
| core-bancario-mock | .NET 8 · 4 APIs mock | `9401`–`9404` |

> Portas de "dev local" (`dotnet run`/`uvicorn`, seção 3 do [`runbook.md`](../runbook.md)). Via `docker compose up -d`, `conversation-orchestrator` e `renegotiation-service` são expostos no host em portas diferentes (`5268` e `5266` — hardcoded em `docker-compose.yml`); ver a tabela completa em [`runbook.md` § Mapa de portas](../runbook.md#mapa-de-portas--resumo). A comunicação serviço-a-serviço usa sempre a rede interna do Docker, então esse detalhe só importa para quem testa via `curl` do host.

**Tópicos Kafka observados:** `channel.webhook.received`, `channel.message.received`, `channel.message.status`, `tool.executed`, `agent.events`, `intent.detected`, `conversation.state_changed`.

**Lacunas / contratos assumidos** (sem implementação neste workspace):

- **Knowledge Service / RAG** (`:8500`) — usado pelo agente para `search_knowledge_base`; formato de resposta é assumido, sem verificação.
- **Salesforce CRM / Data Lake** — existem apenas nos documentos de arquitetura; nenhum código do repositório modela essa integração.

> **Audit Service** (`:8300`, `conversation-audit-service`) deixou de ser uma lacuna: validado em 2026-07-13 como mock com a chamada do Orchestrator comentada ([relatório](../validation/2026-07-13-e2e-journey.md)), o serviço real foi implementado e integrado em 2026-07-18 — `conversation-orchestrator` já chama `POST /journey-events` de verdade ao fim de cada mensagem processada. Ver [`docs/services/conversation-orchestrator.md`](../services/conversation-orchestrator.md#dependências-síncronas).
>
> **Handoff Service** (`:8200`, `conversation-handoff-service`) também deixou de ser uma lacuna: diferente do Audit Service, a chamada do Orchestrator (`POST /handoffs`) nunca esteve comentada — ela só falhava sempre porque apontava para um host sem backend. Implementado e integrado em 2026-07-18: agora aponta para o `conversation-handoff-service` real, e o timeout artificialmente curto que existia só por causa da indisponibilidade permanente foi removido. Ver [`docs/services/conversation-orchestrator.md`](../services/conversation-orchestrator.md#dependências-síncronas).

Toda a cadeia é resiliente por desenho: falhas downstream nunca derrubam o serviço upstream — degradam para handoff (agente) ou `502` (renegotiation-service, apenas quando o Core Bancário está genuinamente inacessível).

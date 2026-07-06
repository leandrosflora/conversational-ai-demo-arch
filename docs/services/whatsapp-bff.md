# whatsapp-bff

Repo: [`leandrosflora/whatsapp-bff`](https://github.com/leandrosflora/whatsapp-bff) · Stack: .NET 8, Minimal API, Confluent.Kafka · Porta local: `5153`

## Responsabilidade principal

Channel BFF entre o WhatsApp Cloud API e o `conversation-orchestrator`. Recebe e valida os webhooks do WhatsApp, persiste a entrega bruta no Kafka antes de confirmar recebimento (garantindo que uma queda do processo não perca mensagens já aceitas), encaminha mensagens de forma assíncrona para o Orchestrator com retry-until-success, e expõe um endpoint interno para enviar respostas de volta ao cliente pela Graph API.

Funções principais:
- Verificar o webhook configurado na Meta (`GET /webhooks/whatsapp`).
- Validar a assinatura HMAC-SHA256 (`X-Hub-Signature-256`) de cada entrega.
- Deduplicar entregas repetidas por `message.id`.
- Publicar o payload bruto no Kafka antes de confirmar o recebimento à Meta.
- Consumir esse mesmo tópico e encaminhar as mensagens ao Orchestrator.
- Publicar eventos canônicos de mensagem recebida/status.
- Enviar mensagens de saída pela WhatsApp Cloud API.

## Dados que o serviço possui

Modelos de domínio (`Domain/`): `InboundChannelMessage`, `MessageStatusEvent` (+ `StatusError`), `OutboundChannelMessage`, `InteractiveReply`, `ChannelMessageType` (enum `Text=0, Interactive=1, Unsupported=2` — ordem fixa por compatibilidade de serialização com o `conversation-orchestrator`), `MessageDeliveryStatus`. Nenhum desses modelos é persistido — vivem apenas durante o processamento de uma requisição/mensagem Kafka.

## APIs publicadas

| Método | Rota | Descrição |
|---|---|---|
| `GET` | `/webhooks/whatsapp` | Handshake de verificação do webhook (`hub.mode`, `hub.verify_token`, `hub.challenge`) |
| `POST` | `/webhooks/whatsapp` | Recebe entregas do WhatsApp Cloud API (mensagens e eventos de status) |
| `POST` | `/internal/messages` | Endpoint interno usado pelo Orchestrator para enviar uma resposta ao cliente |

`POST /webhooks/whatsapp` retorna `200 OK` (aceito ou duplicado descartado), `400 Bad Request` (payload inválido), `401 Unauthorized` (assinatura ausente/inválida) ou `503 Service Unavailable` (falha ao persistir no Kafka — sinaliza a Meta para reentregar). `POST /internal/messages` retorna `202 Accepted` com `messageId`, `400 Bad Request` (`to`/`text` ausentes) ou `502 Bad Gateway` (falha na WhatsApp Cloud API).

## Eventos publicados

| Tópico | Quando | Payload | Falha é engolida? |
|---|---|---|---|
| `channel.webhook.received` | Sempre, antes de responder ao webhook (síncrono dentro do request) | JSON bruto da entrega; chave = telefone do remetente; header `CorrelationId` | **Não** — falha vira `503`, propositalmente |
| `channel.message.received` | Após o forward ao Orchestrator ter sucesso | `InboundChannelMessage` | Sim (catch-log-continue) |
| `channel.message.status` | Para cada evento de status recebido do WhatsApp | `MessageStatusEvent` (com `IsKnownMessage`) | Sim (catch-log-continue) |

## Eventos consumidos

`channel.webhook.received` — consumido pelo próprio processo via `KafkaWebhookConsumerService` (grupo `whatsapp-bff-webhook-consumer`), não por outro serviço.

## Dependências síncronas

| Destino | Chamada | Comportamento se indisponível |
|---|---|---|
| `conversation-orchestrator` (`:8000`) | `POST /messages` | Offset do Kafka só é commitado se o forward tiver sucesso; se falhar, `Seek` de volta ao mesmo offset e retry a cada ~2s (backpressure, sem perda) |
| WhatsApp Cloud API (Graph API) | `POST /{phone-number-id}/messages` | Falha vira `502 Bad Gateway` no `POST /internal/messages` |

## Persistência & infraestrutura

- **Kafka**: única infraestrutura de persistência real usada — tanto como fila durável de entrada (`channel.webhook.received`) quanto como saída de eventos canônicos.
- **Deduplicação de mensagens**: em memória (`IMessageDedupeStore`), perdida em restart.
- **Rastreamento de mensagens outbound conhecidas**: em memória, também perdido em restart.
- Sem banco de dados.

## Regras de negócio

1. O webhook só é confirmado (`200 OK`) à Meta depois que o payload bruto foi duravelmente publicado no Kafka — nunca antes.
2. O consumer Kafka só avança o offset se **todas** as mensagens daquela entrega forem encaminhadas com sucesso ao Orchestrator; falha parcial re-processa a entrega inteira no retry (mensagens já encaminhadas podem ser reenviadas).
3. Um payload de webhook que não pode ser desserializado de volta (poison message) é descartado e commitado — não fica preso em retry infinito, já que reprocessar os mesmos bytes nunca teria sucesso.
4. Deduplicação: uma entrega só é considerada duplicada se **todos** os `message.id` nela já tiverem sido processados antes.

## Referências de arquitetura

- [ADR 0001 — Kafka como fila durável de entrada de webhook](../adr/0001-kafka-durable-webhook-queue.md)
- [ADR 0004 — Resiliência catch-log-continue](../adr/0004-catch-log-continue-resilience.md)
- [Diagramas de sequência da jornada](../architecture/sequence-diagrams.md)

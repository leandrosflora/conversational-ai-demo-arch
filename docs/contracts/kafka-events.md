# Eventos Kafka

**Fonte de verdade:** varredura do código-fonte em 2026-07-06 (ver [`services-map.md`](services-map.md)).

## Regra de leitura deste documento

"Producer" e "Consumer" listam **apenas** o que foi encontrado implementado no código — não o que está descrito em specs/design docs antigos. Um tópico sem consumer listado significa que nenhum serviço deste workspace lê dele hoje (não que ele "deveria" ter um).

## Tópicos implementados

| Tópico | Producer | Consumer | Status |
|---|---|---|---|
| `channel.webhook.received` | whatsapp-bff (`WhatsAppWebhookEndpoints`, síncrono, antes do ack) | whatsapp-bff (`KafkaWebhookConsumerService`, grupo `whatsapp-bff-webhook-consumer`) | Implementado — produtor e consumidor no mesmo serviço |
| `channel.message.received` | whatsapp-bff (após forward ao Orchestrator ter sucesso) | Nenhum | Produzido sem consumidor |
| `channel.message.status` | whatsapp-bff | Nenhum | Produzido sem consumidor |
| `intent.detected` | conversation-orchestrator | Nenhum | Produzido sem consumidor |
| `conversation.state_changed` | conversation-orchestrator | Nenhum | Produzido sem consumidor |
| `agent.events` | agent-runtime-renegotiation | Nenhum | Produzido sem consumidor |
| `tool.executed` | tool-service-renegotiation | Nenhum | Produzido sem consumidor |

## Tópicos configurados em consumer, mas sem producer implementado

Nenhum encontrado — todos os consumers existentes (`KafkaWebhookConsumerService`) têm um producer correspondente no mesmo tópico.

## Observação sobre o padrão geral

Com exceção de `channel.webhook.received` (que existe especificamente para dar durabilidade ao webhook antes do ack — ver [ADR 0001](../adr/0001-kafka-durable-webhook-queue.md)), **nenhum tópico publicado neste workspace tem um consumidor real**. Todos os outros 5 tópicos servem hoje como trilha de auditoria/observabilidade potencial (kafka-console-consumer, ferramentas externas), não como mecanismo de integração entre os serviços implementados — a integração real acontece via chamadas HTTP síncronas (ver [`services-map.md`](services-map.md) e as páginas em [`docs/services/`](../services/)).

## Publish engolido vs. propagado

Por padrão, falha ao publicar em Kafka é sempre "catch-log-continue" (nunca derruba o request que a originou) — ver [ADR 0004](../adr/0004-catch-log-continue-resilience.md). A **única exceção** é `channel.webhook.received`: uma falha de publicação aí é propositalmente propagada como `503` pelo `whatsapp-bff`, porque é o único tópico do qual a durabilidade da mensagem depende.

| Tópico | Falha de publish é engolida? |
|---|---|
| `channel.webhook.received` | **Não** — propaga como `503` |
| `channel.message.received` | Sim |
| `channel.message.status` | Sim |
| `intent.detected` | Sim |
| `conversation.state_changed` | Sim |
| `agent.events` | Sim |
| `tool.executed` | Sim |

## Matriz resumida

| Tópico | Producer | Consumer principal | Classificação |
|---|---|---|---|
| `channel.webhook.received` | whatsapp-bff | whatsapp-bff (interno) | Fila durável |
| `channel.message.received` | whatsapp-bff | — | Auditoria/observabilidade |
| `channel.message.status` | whatsapp-bff | — | Auditoria/observabilidade |
| `intent.detected` | conversation-orchestrator | — | Auditoria/observabilidade |
| `conversation.state_changed` | conversation-orchestrator | — | Auditoria/observabilidade |
| `agent.events` | agent-runtime-renegotiation | — | Auditoria/observabilidade |
| `tool.executed` | tool-service-renegotiation | — | Auditoria/observabilidade |

## Decisão prática

Se você precisa reagir a algum desses eventos hoje, precisará escrever um consumer novo — nenhum existe além do `KafkaWebhookConsumerService`. Isso é intencional neste estágio do projeto (ver [`docs/runbook.md` §7](../runbook.md)), não uma lacuna acidental.

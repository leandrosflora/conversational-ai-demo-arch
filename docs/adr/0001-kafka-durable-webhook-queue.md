# ADR 0001: Usar Kafka como fila durável entre o webhook do WhatsApp e o Orchestrator

## Status

Aceito e implementado (retroativo — este ADR documenta uma decisão já tomada durante o desenvolvimento do `whatsapp-bff`, não uma proposta futura).

**Serviço afetado:** [`whatsapp-bff`](../services/whatsapp-bff.md).

## Contexto

A primeira versão do `whatsapp-bff` enfileirava webhooks recebidos em um `System.Threading.Channels.Channel<T>` **em memória**, e só depois disso retornava `200 OK` para a Meta. Um `BackgroundService` separado lia dessa fila e encaminhava as mensagens ao `conversation-orchestrator`.

O problema: se o processo caísse (deploy, crash, OOM) entre o `200 OK` e o `BackgroundService` conseguir encaminhar a mensagem, ela era perdida — e como a Meta já tinha recebido `200 OK`, ela nunca reentregava o webhook. Numa plataforma de renegociação de dívidas bancária, perder silenciosamente uma mensagem de cliente é inaceitável, especialmente dado o requisito de rastreabilidade completa já declarado em `docs/context/business-context.md`.

## Decisão

Substituir a fila em memória por um tópico Kafka (`channel.webhook.received`) como o mecanismo de durabilidade real:

1. O endpoint `POST /webhooks/whatsapp` publica o payload bruto no Kafka **antes** de responder `200 OK`. Se a publicação falhar, o endpoint responde `503`, para que a Meta reentregue.
2. Um `KafkaWebhookConsumerService` (consumer Kafka, não mais um leitor de canal em memória) consome esse tópico e faz o forward ao Orchestrator.
3. O commit do offset só ocorre se o forward tiver sucesso; em caso de falha, o consumer dá `Seek` de volta ao mesmo offset e tenta novamente após um backoff curto (~2s) — não commitar sozinho não seria suficiente, porque `Consume()` avança independentemente do commit.

## Consequências positivas

- Uma mensagem aceita pelo webhook nunca mais se perde silenciosamente, mesmo com o processo caindo logo em seguida.
- Indisponibilidade do Orchestrator vira backpressure visível (retry contínuo, logado) em vez de perda silenciosa.
- O tópico serve, de quebra, como trilha de auditoria do payload bruto recebido.

## Consequências negativas

- Uma falha no forward faz o consumer reprocessar a entrega inteira — se ela contiver várias mensagens do WhatsApp e só uma falhar, as demais (já encaminhadas com sucesso) podem ser reenviadas ao Orchestrator.
- Introduz uma dependência rígida do Kafka no caminho crítico do webhook: se o Kafka estiver fora do ar, o `whatsapp-bff` responde `503` em vez de aceitar a mensagem — antes, ele sempre aceitava (com o risco de perda que motivou esta mudança).
- Mais um componente (o `KafkaWebhookConsumerService`) para operar e observar.

## Regras

- O offset de `channel.webhook.received` só é commitado após o forward ao Orchestrator ter sucesso para **todas** as mensagens da entrega.
- Uma mensagem que não pode ser desserializada de volta (payload corrompido) é tratada como *poison message*: logada como erro e commitada (não retentada indefinidamente), já que reprocessar os mesmos bytes nunca teria sucesso.
- O `CorrelationId` da entrega original é propagado como header Kafka, para permitir correlação de logs ponta a ponta.

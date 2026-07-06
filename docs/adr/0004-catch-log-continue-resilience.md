# ADR 0004: Resiliência por "catch-log-continue" — downstream nunca derruba upstream

## Status

Aceito e implementado (retroativo).

**Serviços afetados:** todos — [`whatsapp-bff`](../services/whatsapp-bff.md), [`conversation-orchestrator`](../services/conversation-orchestrator.md), [`agent-runtime-renegotiation`](../services/agent-runtime-renegotiation.md), [`tool-service-renegotiation`](../services/tool-service-renegotiation.md), [`renegotiation-service`](../services/renegotiation-service.md).

## Contexto

A cadeia de serviços desta plataforma tem várias dependências ainda não implementadas (Handoff Service, Audit Service, Knowledge Service) e outras que podem estar temporariamente fora do ar (Bedrock, Kafka, o próprio Orchestrator). Numa jornada conversacional, uma exceção não tratada em qualquer ponto da cadeia deixaria o cliente sem resposta, sem visibilidade do motivo.

## Decisão

Todo serviço da plataforma segue a mesma filosofia de resiliência: uma falha numa dependência downstream é capturada, logada, e o fluxo principal continua — nunca derruba o processo nem propaga uma exceção não tratada para o chamador. Cada camada tem sua própria forma de "continuar":

- Publicação de eventos Kafka (exceto `channel.webhook.received`): falha é logada como erro e ignorada — o request original segue normalmente.
- Chamadas HTTP para Handoff Service / Audit Service (a partir do `conversation-orchestrator`): falha é logada como warning; o fluxo continua sem bloquear.
- Chamada ao Agent Runtime (a partir do Orchestrator) ou ao Bedrock (a partir do agente): falha, após esgotar retries, degrada para uma decisão explícita de handoff humano — não é apenas ignorada, tem uma consequência de negócio definida.
- Chamada ao Knowledge Service (a partir do agente): falha vira uma mensagem textual de indisponibilidade injetada no contexto do agente, não um erro.
- Chamada ao Core Bancário (a partir do `renegotiation-service`): falha vira `502 Bad Gateway` explícito — a única camada onde a falha *é* repassada ao chamador, porque não há um fallback de negócio sensato nesse ponto.

## Consequências positivas

- Nenhuma indisponibilidade de uma dependência opcional/assumida derruba a jornada inteira.
- O comportamento de degradação é previsível e consistente entre serviços — quem já entendeu um serviço entende o padrão dos outros.
- Ferramentas de teste e desenvolvimento local podem rodar cada serviço isoladamente sem precisar simular todos os downstream.

## Consequências negativas

- Falhas engolidas silenciosamente (a maioria dos casos acima) só são visíveis em log — não há alertas/métricas dedicadas hoje para "quantas publicações de Kafka falharam nesta última hora", por exemplo.
- A exceção deliberada (`channel.webhook.received` propaga como `503`) quebra a uniformidade do padrão e precisa ser lembrada explicitamente por quem for alterar esse código (documentada no [ADR 0001](0001-kafka-durable-webhook-queue.md)).

## Regras

- Nenhuma chamada a uma dependência marcada como "assumida" (Handoff, Audit, Knowledge Service) pode lançar uma exceção não capturada para fora do adapter que a invoca.
- Toda falha engolida deve ser logada com nível apropriado (warning para downstream opcional, error para o que afeta a durabilidade de dados).
- A única exceção documentada a essa regra é a publicação em `channel.webhook.received` (ver ADR 0001) e a chamada ao Core Bancário a partir do `renegotiation-service` (vira `502`, propositalmente).

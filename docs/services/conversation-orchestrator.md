# conversation-orchestrator

Repo: [`leandrosflora/conversation-orchestrator`](https://github.com/leandrosflora/conversation-orchestrator) · Stack: .NET 8, Minimal API, Confluent.Kafka · Porta local: `8000`

## Responsabilidade principal

Orquestra o processamento de uma mensagem inbound de ponta a ponta: recebe a mensagem já normalizada pelo `whatsapp-bff`, consulta o `agent-runtime-renegotiation` para decidir intenção/resposta, mantém o estado da conversa, publica eventos de intenção/estágio, e decide entre enviar a resposta de volta pelo canal ou disparar handoff humano — registrando um evento de auditoria ao final, independentemente do desfecho.

## Dados que o serviço possui

- `ConversationSession` (`ConversationId`, `CreatedAt`, `LastMessageAt`, `JourneyStage`, `LastIntent`) — sessão da conversa, mantida em memória.
- `InboundChannelMessage` — espelha exatamente o modelo do `whatsapp-bff` (mesma ordem de enum, mesma serialização PascalCase), pois é o contrato de entrada entre os dois serviços.

## APIs publicadas

| Método | Rota | Descrição |
|---|---|---|
| `POST` | `/messages` | Recebe uma mensagem inbound normalizada; processa de ponta a ponta antes de responder |

Validação: `400 Bad Request` se `MessageId`, `From` ou `ConversationId` estiverem vazios. Sucesso: `202 Accepted` (sem corpo — o resultado do processamento não é devolvido ao chamador, só os efeitos colaterais: eventos Kafka, chamada ao Channel BFF ou ao Handoff Service).

## Eventos publicados

| Tópico | Quando | Payload |
|---|---|---|
| `intent.detected` | Quando o Agent Runtime retorna um `Intent` não nulo | `ConversationId`, `Intent`, `Confidence`, `DetectedAt` |
| `conversation.state_changed` | Quando o `JourneyStage` muda em relação ao anterior | `ConversationId`, `PreviousStage`, `NewStage`, `ChangedAt` |

Falha ao publicar em qualquer um dos dois é engolida (catch-log-continue) — nunca afeta a resposta `202` do endpoint.

## Eventos consumidos

Nenhum. O serviço é puramente produtor de eventos (não há `IConsumer` nem `BackgroundService` no projeto).

## Dependências síncronas

| Destino | Chamada | Comportamento se indisponível |
|---|---|---|
| `agent-runtime-renegotiation` (`:8100`) | `POST /process` | Após 2 retries (resilience handler, 200ms), degrada para `AgentRuntimeResult.Unavailable()` → força `RequiresHandoff=true`, `HandoffReason="agent_runtime_unavailable"` |
| `whatsapp-bff` (`:5153`) | `POST /internal/messages` | Apenas loga warning; fire-and-forget |
| Handoff Service (`:8200`, **assumido, não implementado**) | `POST /handoffs` | Apenas loga warning |
| Audit Service (`:8300`, **assumido, não implementado**) | `POST /journey-events` | Apenas loga warning |

Todos os 4 clientes HTTP usam `AddStandardResilienceHandler` com `MaxRetryAttempts=2`, `Delay=200ms`.

## Persistência & infraestrutura

- **Sessão da conversa**: em memória (`ConcurrentDictionary`), TTL de 30 minutos (`Session:TtlMinutes`) — se a última mensagem foi há mais que isso, a sessão é recriada do zero (perde `JourneyStage`/`LastIntent`).
- Sem banco de dados. Kafka é usado só como saída de eventos.

## Regras de negócio

1. Ao detectar uma intenção, o `JourneyStage` é forçado para `"processed"`, independentemente do estágio anterior.
2. Toda sessão nova começa em `JourneyStage = "started"`.
3. Resposta ao cliente e handoff humano são mutuamente exclusivos: se `RequiresHandoff=true`, a resposta pelo canal **não** é enviada.
4. Indisponibilidade do Agent Runtime **sempre** força handoff — não há fallback de resposta automática nesse caso.
5. Não há cálculo de confiança no próprio Orchestrator: o campo `Confidence` só é repassado ao evento `intent.detected`; a decisão de handoff vem inteiramente do booleano `RequiresHandoff` que o Agent Runtime já calculou.
6. Evento de auditoria com `Outcome` binário: `"handoff"` ou `"processed"`.

## Referências de arquitetura

- [ADR 0002 — Hexagonal / ports-and-adapters nos serviços .NET](../adr/0002-hexagonal-ports-and-adapters.md)
- [ADR 0004 — Resiliência catch-log-continue](../adr/0004-catch-log-continue-resilience.md)
- [Diagramas de sequência da jornada](../architecture/sequence-diagrams.md)

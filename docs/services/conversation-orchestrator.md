# conversation-orchestrator

Repo: [`leandrosflora/conversation-orchestrator`](https://github.com/leandrosflora/conversation-orchestrator) · Stack: .NET 8, Minimal API, Confluent.Kafka · Porta local (`dotnet run`): `8000` · Porta host via `docker compose up -d`: `5268` (ver [`runbook.md`](../runbook.md#mapa-de-portas--resumo))

## Responsabilidade principal

Orquestra o processamento de uma mensagem inbound de ponta a ponta: recebe a mensagem já normalizada pelo `whatsapp-bff`, consulta o `agent-runtime-renegotiation` para decidir intenção/resposta, mantém o estado da conversa via `conversation-memory-service`, publica eventos de intenção/estágio, registra um evento de jornada no `conversation-audit-service` ao final do processamento, e decide entre enviar a resposta de volta pelo canal ou disparar handoff humano.

## Dados que o serviço possui

- `ConversationSession` (`ConversationId`, `CreatedAt`, `LastMessageAt`, `JourneyStage`, `LastIntent`) — sessão da conversa; o próprio Orchestrator não a persiste, apenas a lê/escreve via `IConversationMemoryClient` a cada mensagem (ver "Dependências síncronas" abaixo).
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
| `agent-runtime-renegotiation` (`:8100`) | `POST /process` | Após 2 retries (resilience handler), degrada para `AgentRuntimeResult.Unavailable()` → força `RequiresHandoff=true`, `HandoffReason="agent_runtime_unavailable"` |
| `whatsapp-bff` (`:5153`) | `POST /internal/messages` | Apenas loga warning; fire-and-forget |
| Handoff Service (`:8200`, **assumido, não implementado**) | `POST /handoffs` | Apenas loga warning |
| `conversation-memory-service` (`:8600`) | `GET`/`PUT /sessions/{conversationId}`, `POST /conversations/{conversationId}/messages` | Cada chamada tem seu próprio timeout de 5s (não herda o `CancellationToken` do request); falha é logada e engolida — sessão/histórico daquela mensagem simplesmente não é persistido, o processamento continua |
| `conversation-audit-service` (`:8300`) | `POST /journey-events` | Mesmo timeout de 5s isolado; falha é logada e engolida — não afeta a resposta ao cliente |

Todos os clientes HTTP síncronos (`agent-runtime-renegotiation`, `whatsapp-bff`, Handoff Service, `conversation-memory-service`, `conversation-audit-service`) são registrados com `AddStandardResilienceHandler(options => { options.Retry.MaxRetryAttempts = 2; options.Retry.Delay = TimeSpan.FromMilliseconds(200); })` (`Program.cs`) — mas esse código só sobrescreve a contagem de retries e o delay *entre* tentativas. O `AttemptTimeout` (10s) e o `TotalRequestTimeout` (30s) padrão do `AddStandardResilienceHandler` **não são sobrescritos**, e são eles — não o `Delay=200ms` — que dominam o tempo real até degradar quando uma tentativa trava em vez de falhar rápido (timeout de conexão/DNS, host inalcançável). Para `conversation-memory-service` e `conversation-audit-service` especificamente, `IngestMessageUseCase` também aplica seu próprio `CancellationTokenSource` de 5s por chamada (`SideEffectCallTimeout`) — essas chamadas não devem ficar presas ao `CancellationToken` do request original (ex.: o `AttemptTimeout` de 10s que `whatsapp-bff` aplica em `POST /messages`), nem travar o processamento se um desses downstream estiver lento.

> **Validado em 2026-07-13** ([relatório](../validation/2026-07-13-e2e-journey.md)): com `agent-runtime-renegotiation` parado, degradar para `AgentRuntimeResult.Unavailable()` levou ~5-8s (falha de DNS, mais rápida que o `AttemptTimeout`); a chamada subsequente ao Handoff Service (inexistente) levou **~30s** (3 tentativas de ~10s cada, cortada pelo `TotalRequestTimeout`) até finalmente logar o warning e concluir com `outcome=handoff` — **~38s no total** para uma única mensagem. "200ms" describe apenas o backoff entre tentativas, não o tempo até a degradação observável pelo cliente.
>
> Na mesma validação, `conversation-memory-service` e `conversation-audit-service` ainda não existiam: a sessão era mantida em `ConcurrentDictionary` local e o `IAuditServiceClient` estava injetado mas com a chamada comentada em `IngestMessageUseCase.cs`. **Atualizado em 2026-07-17** (`conversation-memory-service`) **e 2026-07-18** (`conversation-audit-service`): ambos os serviços foram implementados e o Orchestrator foi cabeado para chamá-los de verdade — a sessão/histórico agora vive em Redis/MongoDB via `conversation-memory-service`, e cada mensagem processada gera uma linha em `ops.audit_events` via `conversation-audit-service`.

## Persistência & infraestrutura

- **Sessão da conversa**: não é persistida pelo próprio Orchestrator — vive em `conversation-memory-service` (Redis, TTL server-side). Se o serviço estiver inacessível, `GetOrCreateSessionAsync` degrada para uma sessão nova em memória só para aquela requisição (`JourneyStage="started"`), que se perde ao final do request.
- **Histórico de mensagens**: também via `conversation-memory-service` (MongoDB `conversation_messages`) — mensagem inbound e reply outbound são anexadas, cada uma com timeout isolado de 5s.
- **Auditoria**: via `conversation-audit-service` (PostgreSQL `ops.audit_events`) — um evento de jornada por mensagem processada, com timeout isolado de 5s.
- O próprio Orchestrator não tem banco de dados direto. Kafka é usado só como saída de eventos.

## Regras de negócio

1. Ao detectar uma intenção, o `JourneyStage` é forçado para `"processed"`, independentemente do estágio anterior.
2. Toda sessão nova começa em `JourneyStage = "started"`.
3. Resposta ao cliente e handoff humano são mutuamente exclusivos: se `RequiresHandoff=true`, a resposta pelo canal **não** é enviada.
4. Indisponibilidade do Agent Runtime **sempre** força handoff — não há fallback de resposta automática nesse caso.
5. Não há cálculo de confiança no próprio Orchestrator: o campo `Confidence` só é repassado ao evento `intent.detected`; a decisão de handoff vem inteiramente do booleano `RequiresHandoff` que o Agent Runtime já calculou.
6. O `Outcome` binário (`"handoff"` ou `"processed"`) é calculado ao fim de `ExecuteAsync`, logado localmente (`ILogger`) e enviado ao Audit Service (`conversation-audit-service`, `POST /journey-events`) junto com `ConversationId`, `Intent` e um timestamp — ver "Dependências síncronas" acima.

## Referências de arquitetura

- [ADR 0002 — Hexagonal / ports-and-adapters nos serviços .NET](../adr/0002-hexagonal-ports-and-adapters.md)
- [ADR 0004 — Resiliência catch-log-continue](../adr/0004-catch-log-continue-resilience.md)
- [Diagramas de sequência da jornada](../architecture/sequence-diagrams.md)

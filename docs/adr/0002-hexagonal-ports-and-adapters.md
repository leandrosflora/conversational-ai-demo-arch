# ADR 0002: Arquitetura hexagonal (ports & adapters) nos serviços .NET

## Status

Aceito e implementado (retroativo — este ADR documenta a convenção estrutural já adotada em todos os serviços .NET desde o início de cada projeto).

**Serviços afetados:** [`whatsapp-bff`](../services/whatsapp-bff.md), [`conversation-orchestrator`](../services/conversation-orchestrator.md), [`renegotiation-service`](../services/renegotiation-service.md).

## Contexto

A plataforma tem 3 serviços .NET (`whatsapp-bff`, `conversation-orchestrator`, `renegotiation-service`) que precisam trocar adapters de infraestrutura (HTTP, Kafka, persistência em memória) sem reescrever a lógica de aplicação — por exemplo, trocar a sessão em memória do Orchestrator por Redis no futuro, ou trocar o Kafka por outro broker, sem tocar nos use cases.

## Decisão

Todos os 3 serviços .NET seguem a mesma estrutura de pastas, correspondendo à arquitetura hexagonal (ports & adapters):

- `Domain/` — modelos de domínio puros, sem dependência de infraestrutura.
- `Application/Ports/Inbound/` — interfaces que os adapters de entrada chamam (ex.: `IIngestMessageUseCase`, `IProcessInboundWebhookUseCase`).
- `Application/Ports/Outbound/` — interfaces que a aplicação usa para falar com o mundo externo (ex.: `IAgentRuntimeClient`, `IChannelEventPublisher`, `IConversationSessionStore`).
- `Application/UseCases/` — implementações das portas inbound; dependem apenas de outras interfaces, nunca de tipos concretos de `Adapters/`.
- `Adapters/Inbound/` — adapters que traduzem um protocolo externo (HTTP, consumer Kafka) para uma chamada de porta inbound.
- `Adapters/Outbound/` — adapters que implementam as portas outbound contra uma tecnologia concreta (HTTP client, Kafka producer/consumer, armazenamento em memória).
- `Configuration/` — classes de opções (`IOptions<T>`), uma por integração externa.

A injeção de dependência (`Program.cs`) é o único lugar que conecta interface a implementação concreta.

## Consequências positivas

- Use cases são testáveis isoladamente com mocks das portas (confirmado pelos testes existentes em cada `*.Tests`, que mockam `IAgentRuntimeClient`, `IChannelEventPublisher` etc. via Moq).
- Trocar um adapter (ex.: sessão em memória → Redis) não exige tocar em `Application/`.
- A mesma convenção em 3 serviços diferentes reduz a carga cognitiva de navegar entre eles.

## Consequências negativas

- Mais arquivos/indireção do que uma estrutura MVC simples, para serviços que hoje têm pouca lógica de negócio própria (ex.: `renegotiation-service` é majoritariamente pass-through).
- Convenção não documentada explicitamente até este ADR — novos contribuidores tinham que inferir o padrão olhando a estrutura de pastas.

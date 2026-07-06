# renegotiation-service

Repo: [`leandrosflora/renegotiation-service`](https://github.com/leandrosflora/renegotiation-service) · Stack: .NET 8, Minimal API · Porta local: `9400`

## Responsabilidade principal

Gateway HTTP que unifica, sob uma API REST própria, as 4 APIs do Core Bancário (mockadas em `core-bancario-mock`): consulta de cliente/contratos/dívidas, elegibilidade, simulação e formalização. **Não contém regra de negócio de crédito própria** — cada use case apenas chama o client outbound correspondente e repassa o resultado (pass-through). As regras de negócio "de renegociação" (o que torna um contrato inelegível, os limites de parcelamento, etc.) vivem no `core-bancario-mock`, não aqui.

## Dados que o serviço possui

Nenhum modelo persistido — apenas records de wire (`ClientLookupResult`, `ContractsResult`, `DebtsResult`, `EligibilityResult`, `SimulationResult`, `AgreementConfirmationResult`, `DocumentResult`).

## APIs publicadas

| Método | Rota | Chama (core-bancario-mock) |
|---|---|---|
| `GET` | `/clients/{cpf}` | ClientApi `:9401` |
| `GET` | `/clients/{clientId}/contracts` | ClientApi `:9401` |
| `GET` | `/contracts/{contractId}/debts` | ClientApi `:9401` |
| `GET` | `/contracts/{contractId}/eligibility` | EligibilityApi `:9402` |
| `POST` | `/contracts/{contractId}/simulations` | ContractingApi `:9403` |
| `POST` | `/simulations/{simulationId}/confirmations` | FormalizationApi `:9404` |
| `GET` | `/agreements/{agreementId}/document` | FormalizationApi `:9404` |

## Eventos publicados / consumidos

Nenhum. Não há Kafka neste serviço — é puramente síncrono, request/response HTTP.

## Dependências síncronas

As 4 APIs do `core-bancario-mock`, cada uma com `HttpClient` tipado + resilience handler (2 retries configuráveis por API).

## Persistência & infraestrutura

Totalmente stateless, sem banco de dados — toda a informação vem das chamadas HTTP síncronas ao Core Bancário mock.

## Regras de negócio (na verdade, convenção de mapeamento de erro — não regra de crédito)

1. Qualquer resposta HTTP 2xx do Core Bancário — mesmo representando um desfecho negativo de negócio (`eligible:false`, `possible:false`, `confirmed:false`, `available:false`) — é repassada como `200 OK` pelo `renegotiation-service`.
2. Só existe `502 Bad Gateway` quando a chamada ao Core Bancário genuinamente falha (timeout, conexão recusada) — capturado via `UpstreamServiceUnavailableException`, tratado por `try/catch` em cada endpoint (não é middleware global).
3. Um CPF não encontrado no ClientApi (404) é mapeado para `ClientLookupResult(Found: false)` — mas isso só funciona porque o cliente HTTP interpreta 404 como "não encontrado"; **os endpoints de contratos/dívidas (`GetContractsUseCase`/`GetDebtsUseCase`) também tratam esse caso, mas o mock atual não implementa 404 para essas duas rotas** — gap conhecido entre o client e o mock, ver [`docs/services/core-bancario-mock.md`](core-bancario-mock.md).

## Referências de arquitetura

- [ADR 0002 — Hexagonal / ports-and-adapters nos serviços .NET](../adr/0002-hexagonal-ports-and-adapters.md)
- [Matriz de datastores](../contracts/data-stores.md)

# core-bancario-mock

Repo: [`leandrosflora/core-bancario-mock`](https://github.com/leandrosflora/core-bancario-mock) · Stack: .NET 8, Minimal API, processo único · Portas locais: `9401`–`9404`

## Responsabilidade principal

Mock, num único processo (`builder.WebHost.UseUrls(...)` escutando em 4 portas simultaneamente), das 4 APIs bancárias externas que o `renegotiation-service` assume existir: consulta de cliente/contratos/dívidas, elegibilidade, contratação/simulação e formalização. Sem persistência — dados de qualquer CPF fora da tabela de cenários abaixo são gerados inline a cada chamada.

## Dados que o serviço possui

Nenhuma persistência real, mas um conjunto fixo de 10 CPFs reservados (`ScenarioFixtures.ByCpf`, dígito repetido 11x — `00000000000` a `99999999999`, mais um CPF de teste manual `12345678911`) resolve para dados determinísticos de cliente/contratos/dívidas/elegibilidade/simulação/formalização, cobrindo os cenários de negócio da renegociação (inelegibilidade, múltiplos contratos, sem dívida em aberto, simulação que expira, documento pendente etc.) — ver `openspec/changes/validate-renegotiation-flow-scenarios/design.md` e `conversational-ai-demo-arch/docs/homologacao/massa-de-teste-clientes.md`. Qualquer CPF fora dessa lista continua com dado gerado inline a cada chamada (`ContractSummary`, `DebtItem` com valores fixos; IDs de simulação/acordo via `Guid.NewGuid()`).

## APIs publicadas

| Porta | API | Endpoints |
|---|---|---|
| `9401` | ClientApi | `GET /clients/{cpf}` · `GET /clients/{clientId}/contracts` · `GET /contracts/{contractId}/debts` |
| `9402` | EligibilityApi | `GET /contracts/{contractId}/eligibility` |
| `9403` | ContractingApi | `POST /contracts/{contractId}/simulations` |
| `9404` | FormalizationApi | `POST /simulations/{simulationId}/confirmations` · `GET /agreements/{agreementId}/document` |

## Eventos publicados / consumidos

Nenhum — sem Kafka.

## Dependências síncronas

Nenhuma — é o "fim da linha" da cadeia de chamadas.

## Persistência & infraestrutura

Nenhuma. Roda tanto via `dotnet run` local quanto em container (tem `Dockerfile`, usado como `build: context: ../core-bancario-mock` no `docker-compose.yml` deste repo).

## Regras de negócio (gatilhos de teste, verificados no código)

Genéricos, aplicados a qualquer CPF fora da tabela de cenários reservados (ver "Dados que o serviço possui" acima):

| Cenário | Gatilho exato | Resposta |
|---|---|---|
| Cliente não encontrado | `cpf == "00000000000"` | **`404 Not Found`** |
| Contrato não elegível | `contractId` contém `"inelegivel"` (case-insensitive) | `200 OK`, `{eligible:false, reason:"cliente_inadimplente_critico"}` |
| Simulação não possível | `installments <= 0` ou `> 48` | `200 OK`, `{possible:false, reason:"installments_out_of_range"}` |
| Confirmação não possível | `simulationId` contém `"expired"` | `200 OK`, `{confirmed:false, reason:"simulation_expired"}` |
| Documento não disponível | `agreementId` contém `"pendente"` | `200 OK`, `{available:false, reason:"document_not_ready"}` |

Para os 10 CPFs reservados, elegibilidade/simulação-expira/documento-pendente vêm de dados fixos por
CPF em vez desses gatilhos textuais (embora `simulationId`/`agreementId` ainda carreguem os mesmos
marcadores `-expired`/`-pendente` internamente, propagados a partir do CPF do contrato de origem).

**Inconsistência conhecida:** o cabeçalho do código afirma que o mock "sempre retorna 200 OK, nunca 4xx" — mas o handler de `GET /clients/{cpf}` retorna `404 Not Found` para CPF não cadastrado, contradizendo esse comentário. Os demais 4 cenários acima seguem a convenção de sempre `200`. Além disso, os endpoints de contratos e dívidas (`/clients/{clientId}/contracts`, `/contracts/{contractId}/debts`) não implementam nenhum gatilho de "não encontrado" próprio, embora o `renegotiation-service` os trate como se pudessem retornar 404.

## Referências de arquitetura

- [Matriz de datastores](../contracts/data-stores.md)

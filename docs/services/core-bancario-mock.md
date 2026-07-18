# core-bancario-mock

Repo: nenhum — diferente dos demais serviços, não é um repositório git próprio; vive apenas como pasta local (`core-bancario-mock/`) no workspace de desenvolvimento · Stack: .NET 8, Minimal API, processo único · Portas locais: `9401`–`9404`

## Responsabilidade principal

Mock, num único processo (`builder.WebHost.UseUrls(...)` escutando em 4 portas simultaneamente), das 4 APIs bancárias externas que o `renegotiation-service` assume existir: consulta de cliente/contratos/dívidas, elegibilidade, contratação/simulação e formalização. Gera dados fake na hora — não há persistência.

## Dados que o serviço possui

Nenhum — todo dado é gerado inline a cada chamada (`ContractSummary`, `DebtItem` com valores fixos; IDs de simulação/acordo via `Guid.NewGuid()`).

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

Nenhuma. Sem Dockerfile — só `dotnet run` local (perfis `http`/`https` em `launchSettings.json`, `commandName: "Project"`).

## Regras de negócio (gatilhos de teste, verificados no código)

| Cenário | Gatilho exato | Resposta |
|---|---|---|
| Cliente não encontrado | `cpf == "00000000000"` | **`404 Not Found`** |
| Contrato não elegível | `contractId` contém `"inelegivel"` (case-insensitive) | `200 OK`, `{eligible:false, reason:"cliente_inadimplente_critico"}` |
| Simulação não possível | `installments <= 0` ou `> 48` | `200 OK`, `{possible:false, reason:"installments_out_of_range"}` |
| Confirmação não possível | `simulationId` contém `"expired"` | `200 OK`, `{confirmed:false, reason:"simulation_expired"}` |
| Documento não disponível | `agreementId` contém `"pendente"` | `200 OK`, `{available:false, reason:"document_not_ready"}` |

**Inconsistência conhecida:** o cabeçalho do código afirma que o mock "sempre retorna 200 OK, nunca 4xx" — mas o handler de `GET /clients/{cpf}` retorna `404 Not Found` para CPF não cadastrado, contradizendo esse comentário. Os demais 4 cenários acima seguem a convenção de sempre `200`. Além disso, os endpoints de contratos e dívidas (`/clients/{clientId}/contracts`, `/contracts/{contractId}/debts`) não implementam nenhum gatilho de "não encontrado" próprio, embora o `renegotiation-service` os trate como se pudessem retornar 404.

## Referências de arquitetura

- [Matriz de datastores](../contracts/data-stores.md)

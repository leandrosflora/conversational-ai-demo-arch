# tool-service-renegotiation

Repo: [`leandrosflora/tool-service-renegotiation`](https://github.com/leandrosflora/tool-service-renegotiation) · Stack: Python, MCP (FastMCP), Confluent.Kafka · Porta local: `8400`

## Responsabilidade principal

Servidor MCP que expõe, como ferramentas governadas, as operações do fluxo de renegociação — traduzindo cada chamada de tool numa requisição HTTP ao `renegotiation-service` e publicando um evento de auditoria (`tool.executed`) a cada execução, com ou sem sucesso.

## Dados que o serviço possui

Nenhum — é uma camada de tradução fina entre o protocolo MCP e o `renegotiation-service`; não possui modelo de domínio próprio.

## APIs publicadas

Servidor MCP via streamable-HTTP em `/mcp` (porta `8400`) — não é uma API REST. Sete tools expostas:

| Tool | Parâmetros | Endpoint HTTP chamado |
|---|---|---|
| `consultar_cliente` | `cpf` | `GET /clients/{cpf}` |
| `consultar_contratos` | `client_id` | `GET /clients/{client_id}/contracts` |
| `consultar_debitos` | `contract_id` | `GET /contracts/{contract_id}/debts` |
| `validar_elegibilidade` | `contract_id` | `GET /contracts/{contract_id}/eligibility` |
| `simular_proposta` | `contract_id, installments, discount_percentage=0.0` | `POST /contracts/{contract_id}/simulations` |
| `confirmar_acordo` | `simulation_id` | `POST /simulations/{simulation_id}/confirmations` |
| `gerar_documento` | `agreement_id` | `GET /agreements/{agreement_id}/document` |

## Eventos publicados

| Tópico | Quando | Payload |
|---|---|---|
| `tool.executed` | Sempre, em `finally`, após cada chamada de tool (sucesso ou erro) | `tool_name`, `outcome` (`"success"`\|`"error"`), `correlation_id` |

**Importante:** o payload nunca inclui os argumentos da tool (CPF, IDs de contrato/simulação/acordo) — não é mascaramento, é exclusão total, por desenho ("payload intentionally never includes tool arguments... so there is no raw sensitive identifier to leak into the audit trail"). Falha ao publicar é engolida (catch-log-continue).

## Eventos consumidos

Nenhum.

## Dependências síncronas

| Destino | Comportamento se indisponível |
|---|---|
| `renegotiation-service` (`:9400`) | Timeout de 5s por chamada; retry via `tenacity` (2 tentativas extras = 3 no total, 0.2s entre elas); se todas falharem, levanta `RenegotiationServiceUnavailableError` **sem** incluir a mensagem original do erro (evita vazar URL/CPF no log) — a exceção sobe e o FastMCP a converte em `ToolError` para o agente cliente |

## Persistência & infraestrutura

Nenhuma. Sem estado — cada chamada de tool cria um `httpx.AsyncClient` novo (sem connection pooling persistente entre chamadas).

## Regras de negócio

1. Nenhum argumento de tool (dado potencialmente sensível como CPF) é publicado no Kafka, em nenhuma circunstância.
2. Falha de rede/timeout ao chamar o `renegotiation-service` não é capturada como retorno estruturado — vira exceção MCP (`ToolError`) propagada ao agente, não um `{"error": ...}` dentro de um resultado de sucesso.
3. O log de erro do client HTTP registra apenas o tipo da exceção, nunca a mensagem/URL completa (mesmo motivo de proteção de dados sensíveis).

## Referências de arquitetura

- [ADR 0003 — MCP para tool-calling governado](../adr/0003-mcp-governed-tool-calling.md)
- [Segurança da arquitetura](../security/security-architecture.md)
- [Diagramas de sequência da jornada](../architecture/sequence-diagrams.md)

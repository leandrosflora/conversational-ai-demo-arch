# ADR 0003: Usar MCP para tool-calling governado do agente de IA

## Status

Aceito e implementado (retroativo).

**Serviços afetados:** [`agent-runtime-renegotiation`](../services/agent-runtime-renegotiation.md), [`tool-service-renegotiation`](../services/tool-service-renegotiation.md).

## Contexto

O `agent-runtime-renegotiation` precisa executar ações em sistemas corporativos (consultar cliente, simular proposta, confirmar acordo) a partir de decisões de um LLM. Dar ao agente acesso direto a HTTP clients arbitrários tornaria difícil auditar quais ações ele de fato executa, versionar o conjunto de ferramentas disponíveis, e trocar de agente/modelo sem reescrever a integração com o `renegotiation-service`.

## Decisão

Introduzir um servidor MCP dedicado (`tool-service-renegotiation`) como a única porta de entrada para ações do agente sobre o domínio de renegociação. O `agent-runtime-renegotiation` se conecta a ele via `strands.tools.mcp.MCPClient` sobre streamable-HTTP, listando as tools disponíveis a cada requisição. O servidor MCP expõe 7 tools (`consultar_cliente`, `consultar_contratos`, `consultar_debitos`, `validar_elegibilidade`, `simular_proposta`, `confirmar_acordo`, `gerar_documento`), cada uma mapeada 1:1 para um endpoint do `renegotiation-service`, e publica um evento de auditoria (`tool.executed`) a cada execução.

## Consequências positivas

- Toda ação do agente sobre o domínio passa por um ponto único, auditável (evento Kafka por chamada).
- O conjunto de tools é declarado e versionado no `tool-service-renegotiation`, não espalhado pelo código do agente.
- Argumentos sensíveis (CPF, IDs) nunca são publicados no evento de auditoria — apenas nome da tool e desfecho.
- Se o `tool-service-renegotiation` estiver indisponível, o agente degrada (segue sem essas tools) em vez de falhar todo o processamento.

## Consequências negativas

- Uma camada extra de indireção (agente → MCP → HTTP → Core Bancário mock) para cada ação, com custo de latência.
- Erros do `renegotiation-service` chegam ao agente como `ToolError` do protocolo MCP, não como um retorno estruturado — o agente precisa saber interpretar esse tipo de falha.

## Regras

- Toda tool exposta pelo `tool-service-renegotiation` deve corresponder a exatamente um endpoint do `renegotiation-service`; nenhuma lógica de negócio adicional é implementada na camada MCP.
- O payload do evento `tool.executed` nunca inclui os argumentos da tool.

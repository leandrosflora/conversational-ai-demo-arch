# agent-runtime-renegotiation

Repo: [`leandrosflora/agent-runtime-renegotiation`](https://github.com/leandrosflora/agent-runtime-renegotiation) · Stack: Python, FastAPI, Strands Agents, OpenAI · Porta local: `8100`

## Responsabilidade principal

Hospeda o agente de IA (Strands Agents + OpenAI) que conduz a jornada de renegociação: recebe uma mensagem do Orchestrator, monta as ferramentas disponíveis (tools MCP do `tool-service-renegotiation` + tool de knowledge base/RAG), invoca o modelo para produzir uma decisão estruturada (intenção, confiança, texto de resposta, necessidade de handoff), publica um evento de auditoria no Kafka e devolve a decisão.

## Dados que o serviço possui

Nenhum modelo persistido — `ProcessRequest`/`ProcessResponse` (Pydantic, `app/models.py`) são contratos de wire, não dados de domínio armazenados.

## APIs publicadas

| Método | Rota | Descrição |
|---|---|---|
| `POST` | `/process` | Processa uma mensagem e devolve a decisão do agente |

Request (`ProcessRequest`, PascalCase — espelha o que o Orchestrator envia): `ConversationId`, `MessageType`, `Text?`, `JourneyStage?`, `LastIntent?`.
Response (`ProcessResponse`, PascalCase): `Intent?`, `Confidence` (default `0.0`), `ReplyText?`, `RequiresHandoff` (default `false`), `HandoffReason?`. Sempre `200 OK` — não há tratamento explícito de exceção não capturada em `main.py`, o design assume que a lógica do agente nunca propaga.

## Eventos publicados

| Tópico | Quando | Payload | Falha é engolida? |
|---|---|---|---|
| `agent.events` | Sempre, ao final de cada `/process` | `conversation_id`, `intent`, `confidence`, `requires_handoff`, `handoff_reason` | Sim — "nunca falha o request", documentado explicitamente no código |

## Eventos consumidos

Nenhum.

## Dependências síncronas

| Destino | Protocolo | Comportamento se indisponível |
|---|---|---|
| `tool-service-renegotiation` (`:8400`, MCP) | streamable-HTTP, via `strands.tools.mcp.MCPClient` | Se a conexão/listagem de tools falhar, o agente segue sem essas tools (não bloqueia o request) |
| OpenAI (`gpt-4o-mini` por padrão) | SDK Strands, via `OpenAIModel` | Sem `OPENAI_API_KEY` ou falha do modelo → captura genérica → degrada para decisão de handoff (`requires_handoff=true`, `handoff_reason="agent_runtime_unavailable"`) |
| Knowledge Service (`:8500`, **assumido, não implementado**) | `GET /search?query=...` (httpx) | Retry via `tenacity` (3 tentativas, 0.2s entre elas); se todas falharem, retorna ao agente a string `"Base de conhecimento indisponivel no momento."` em vez de erro |

## Persistência & infraestrutura

Nenhuma persistência própria. O único estado é o resultado momentâneo de uma chamada `/process` (sem sessão, sem cache).

## Regras de negócio

1. **Threshold de confiança = 0.6** (configurável): se `decision.confidence < 0.6`, força `requires_handoff=true` mesmo que o agente não tenha pedido, com motivo `"low_confidence"` (a menos que o agente já tenha especificado outro motivo).
2. Falha total do LLM (sem credenciais, throttling etc.) nunca vira erro HTTP — degrada para uma decisão de handoff com motivo `"agent_runtime_unavailable"`.
3. Falha ao conectar no Tool Service MCP não bloqueia o processamento — o agente simplesmente não tem acesso a essas tools naquele turno.
4. Falha na Knowledge Base vira uma mensagem textual de indisponibilidade injetada no contexto do agente, não um erro.
5. Falha ao publicar em Kafka nunca falha o request.

## Referências de arquitetura

- [ADR 0003 — MCP para tool-calling governado](../adr/0003-mcp-governed-tool-calling.md)
- [ADR 0004 — Resiliência catch-log-continue](../adr/0004-catch-log-continue-resilience.md)
- [Diagramas de sequência da jornada](../architecture/sequence-diagrams.md)

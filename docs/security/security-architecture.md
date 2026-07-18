# Arquitetura de segurança — estado implementado P1

Este documento descreve controles **existentes no código** e lacunas restantes. A arquitetura-alvo está em `docs/architecture/C4/c4-container-target.puml`.

## 1. Fronteiras de confiança

| Fronteira | Controle implementado |
|---|---|
| WhatsApp → BFF | verify token no handshake e HMAC-SHA256 no corpo do webhook |
| Serviço → serviço | JWT HS256 curto, com `iss`, `sub`, `aud`, `iat` e `exp` |
| Tenant → serviço | `X-Tenant-Id` obrigatório e propagado pela cadeia |
| BFF → Kafka | persistência confirmada antes do ACK; trace W3C nos headers |
| Operações mutáveis | `Idempotency-Key` e retry automático desabilitado |
| Dados de sessão/RAG | segregação física/lógica por tenant |

## 2. Autenticidade do webhook

`whatsapp-bff` valida:

- `hub.verify_token` no `GET /webhooks/whatsapp`;
- `X-Hub-Signature-256` no POST;
- HMAC-SHA256 calculado sobre os bytes originais do corpo;
- rejeição com `401` antes de Kafka ou parsing de negócio.

O webhook continua público por necessidade do provedor. `/internal/messages` não é público: exige JWT com audiência `whatsapp-bff`.

## 3. Autenticação service-to-service

Serviços P1 validam JWT Bearer com:

```text
issuer   = conversational-ai-platform
subject  = serviço chamador
audience = serviço destino
exp      = até 300 segundos por padrão
alg      = HS256
```

O segredo não é versionado. `docker-compose.override.yml` exige `INTERNAL_AUTH_SIGNING_KEY` no `.env` e falha na interpolação quando ausente.

Audiências atuais:

| Destino | `aud` esperado |
|---|---|
| whatsapp-bff | `whatsapp-bff` |
| conversation-orchestrator | `conversation-orchestrator` |
| agent-runtime-renegotiation | `agent-runtime-renegotiation` |
| tool-service-renegotiation | `tool-service-renegotiation` |
| renegotiation-service | `renegotiation-service` |
| knowledge-service | `knowledge-service` |
| conversation-memory-service | `conversation-memory-service` |
| conversation-audit-service | `conversation-audit-service` |
| conversation-handoff-service | `conversation-handoff-service` |

### Limitação

HS256 compartilhado melhora a POC, mas não é o estado final desejado. Comprometimento de um serviço expõe a chave usada pelos demais. Produção deve usar uma destas opções:

- workload identity com OAuth2 client credentials;
- JWT assimétrico com JWKS e rotação;
- mTLS/service mesh;
- identidade nativa da plataforma cloud.

## 4. Endpoints protegidos

Exigem JWT e, para operações de negócio, `X-Tenant-Id`:

- `POST /messages`;
- `POST /process`;
- MCP/REST do Tool Service;
- todas as capacidades do Renegotiation Service;
- `POST /internal/messages`;
- `GET /search`;
- `POST /admin/reindex`;
- APIs de sessão, histórico e memória;
- `POST /journey-events`;
- `POST /handoffs`.

Permanecem anônimos:

- webhook/handshake do WhatsApp, protegidos por HMAC/verify token;
- `/health/live`, `/health/ready`, `/metrics`.

Em uma implantação exposta, métricas e health devem ficar em listener/rede operacional, não na internet pública.

## 5. Multitenancy

### 5.1 Fonte de autoridade

O tenant canônico vem de `X-Tenant-Id` em uma chamada autenticada. Body/query não podem selecionar livremente outro tenant; divergências são rejeitadas.

### 5.2 Memory Service

- Redis: `tenant:{tenantId}:session:{conversationId}`;
- MongoDB: queries incluem `tenantId`;
- histórico e memória longa rejeitam body com tenant divergente;
- listagem de mensagens não aceita mais tenant arbitrário em query string.

### 5.3 Knowledge Service

- um índice OpenSearch físico por tenant;
- diretório de ingestão por tenant;
- tenant diferente do padrão nunca reutiliza o diretório legado compartilhado;
- `/admin/reindex` exige workload autenticado e tenant.

Índice físico foi escolhido para reduzir o risco de vazamento causado por esquecimento de filtro em busca vetorial.

### 5.4 Audit e Handoff

Audit persiste o tenant autenticado em `ops.audit_events.tenant_id`.

Handoff ainda usa uma conversa seed devido ao modelo atual; o tenant e o ID externo real são preservados no metadata. Isso é compatibilidade de POC, não modelo final.

## 6. Idempotência e integridade

- BFF só conclui o dedupe após confirmação do Kafka.
- Orchestrator usa Inbox PostgreSQL com lease.
- Audit e Handoff usam índices únicos por `Idempotency-Key`.
- confirmação de acordo usa chave estável baseada na simulação.
- clients não repetem automaticamente métodos HTTP inseguros.
- produtor Kafka da entrada usa idempotência e `acks=all`.

## 7. Kafka, poison e DLQ

`whatsapp-bff` possui:

- tópico de entrada;
- tópico de retry durável;
- DLQ;
- contador de tentativas em header;
- limite configurável;
- commit somente após retry/DLQ confirmado;
- preservação de payload e origem na DLQ.

JSON inválido e payload nulo são considerados poison e não entram em retry infinito.

## 8. PII e logging

Implementado:

- `tool.executed` não inclui argumentos de tools;
- exceptions do client de renegociação não registram URL completa;
- Agent Runtime não registra mais o corpo completo de requests inválidos;
- métricas usam labels de cardinalidade controlada, sem CPF, contrato ou conversation ID;
- logs operacionais devem usar tenant, trace ID e correlation ID, não conteúdo da mensagem.

Ainda necessário:

- redaction centralizada de logs;
- classificação de campos e DLP;
- política de retenção por tipo de dado;
- processo LGPD de acesso, correção e exclusão;
- criptografia em repouso gerenciada fora do ambiente local.

## 9. Segredos

Arquivos versionados contêm valores vazios ou placeholders, nunca o segredo real. O ambiente ainda não possui:

- secret scanning obrigatório;
- cofre integrado;
- rotação automática;
- revogação por serviço;
- chaves distintas por ambiente.

Esses controles são obrigatórios antes de produção.

## 10. Health e métricas

Todos os serviços acessíveis expõem liveness/readiness/metrics. Readiness falha quando autenticação não está configurada e, conforme o serviço, quando Kafka, PostgreSQL, Redis, MongoDB, OpenSearch ou OpenAI não estão disponíveis/configurados.

Prometheus coleta métricas de:

- autenticação rejeitada;
- status/duração HTTP;
- retry/DLQ/poison;
- Inbox e outcomes;
- handoff de IA;
- execução de tools;
- busca/reindexação RAG;
- memória;
- auditoria e handoff.

Alertas ainda não estão configurados; apenas as séries foram expostas.

## 11. Lacunas críticas restantes

1. **Core Bancário Mock**: recebe JWT e tenant, mas o repositório não estava acessível para implementar validação, health e métricas.
2. **OpenSearch local**: plugin de segurança desabilitado; porta deve ficar restrita à máquina/rede de desenvolvimento.
3. **Kafka local**: sem TLS/SASL/ACL e sem Schema Registry.
4. **Rede**: sem NetworkPolicy, service mesh ou segmentação efetiva.
5. **Identidade**: segredo HMAC compartilhado, sem rotação/JWKS.
6. **Handoff**: não integra sistema humano real.
7. **Supply chain**: sem CI obrigatório, SAST, SCA, assinatura de imagem ou SBOM.
8. **Rate limiting/WAF**: ainda não implementados no workspace.
9. **Criptografia em repouso**: depende da futura plataforma de execução.

## 12. Critério para chamar de production-ready

Não usar esse rótulo enquanto as lacunas 1–8 acima não tiverem owner, implementação, teste e evidência operacional. O P1 transforma a solução em **POC endurecida e arquiteturalmente coerente**, não em plataforma bancária pronta para produção.

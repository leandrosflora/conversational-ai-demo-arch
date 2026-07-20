# Arquitetura de segurança — estado implementado P0/P1

Este documento descreve controles existentes no código. A arquitetura-alvo permanece em `docs/architecture/C4/c4-container-target.puml`.

## 1. Fronteiras de confiança

| Fronteira | Controle implementado |
|---|---|
| WhatsApp → BFF | verify token no handshake e HMAC-SHA256 sobre o corpo original |
| Serviço → serviço | JWT HS256 curto com `iss`, `sub`, `aud`, `iat`, `exp`, `jti` e `tenant_id` |
| Tenant → serviço | UUID canônico presente simultaneamente em claim assinada e `X-Tenant-Id` |
| Agent Runtime → Tool Service | JWT `tool_execution` com conversa, mensagem, estágio, versão e evidência de confirmação |
| Tool Service → Renegotiation Service | JWT `governed_tool` com tool autorizada e `policy_id` ligado à `Idempotency-Key` |
| Entrada → negócio | Kafka confirmado antes do ACK; Inbox e estado transacionais |
| Side effects | Outbox durável, replay at-least-once e deduplicação no destino |
| Dados | chaves, queries e índices tenant-scoped |

## 2. Autenticidade do webhook

`whatsapp-bff` valida:

- `hub.verify_token` no handshake;
- `X-Hub-Signature-256` no POST;
- HMAC-SHA256 calculado sobre os bytes originais;
- rejeição antes de parsing de negócio ou publicação Kafka.

O webhook é público por necessidade do provedor. `/internal/messages` é interno e exige JWT, tenant assinado e `Idempotency-Key`.

## 3. Identidade interna

### 3.1 Claims comuns

```text
iss       = conversational-ai-platform
sub       = serviço chamador
aud       = serviço destino
tenant_id = UUID canônico do tenant
iat/exp   = validade curta
jti       = identificador do token
alg       = HS256
```

O destino compara `tenant_id` com `X-Tenant-Id`. Ausência, UUID vazio, formato inválido ou divergência são rejeitados.

O body pode repetir tenant para compatibilidade de contrato, mas não é fonte de autoridade.

### 3.2 Tokens de execução de tools

O Agent Runtime emite token `tool_execution` contendo:

- `conversation_id`;
- `message_id`;
- `journey_stage`;
- `journey_version`;
- `confirmation_message_id`, quando uma confirmação explícita foi reconhecida deterministicamente.

O Tool Service aceita apenas o caller `agent-runtime-renegotiation` e estabelece o contexto a partir dessas claims.

### 3.3 Prova de policy para o domínio

Depois de autorizar a tool, o Tool Service emite token `governed_tool` com:

- `tool_name`;
- o mesmo contexto da jornada;
- `policy_id` igual à chave idempotente da operação.

O Renegotiation Service exige:

- caller `tool-service-renegotiation`;
- operação assinada correspondente ao endpoint;
- estágio permitido;
- `policy_id` igual ao header `Idempotency-Key`;
- para confirmação, `confirmation_message_id == message_id`.

Assim, prompt ou tool call do LLM não são suficientes para autorizar uma operação financeira.

### Limitação de identidade

Desde a mudança `per-service-internal-auth-secrets`, não existe mais um segredo HS256 único compartilhado por toda a plataforma: cada par (emissor, audiência) — ex. `whatsapp-bff → conversation-orchestrator`, `agent-runtime-renegotiation → tool-service-renegotiation` — tem seu próprio segredo. O token de saída carrega um header `kid` igual ao nome do serviço emissor; quem valida resolve a chave a partir de uma allow-list própria de chamadores esperados (`InboundSecrets`/`internal_auth_inbound_secrets`) e rejeita qualquer `kid` fora dela antes mesmo de tentar verificar a assinatura — a identidade do chamador só é considerada provada depois que a assinatura verifica com a chave daquele par específico, nunca pelo `kid`/`sub` isoladamente. Isso reduz o raio de dano de um serviço comprometido: ele só consegue forjar tokens para os pares dos quais já fazia parte, não para toda a malha.

Isso ainda é HS256 simétrico, sem rotação automatizada — comprometer um dos dois lados de um par ainda expõe aquele segredo específico. Produção deve migrar para:

- workload identity/OAuth2;
- JWT assimétrico com JWKS e rotação;
- mTLS/service mesh;
- credenciais e políticas distintas por workload.

## 4. Multitenancy

O contrato único de tenant é UUID não vazio em formato canônico.

### Memory Service

- Redis: `tenant:{tenantId}:session:{conversationId}`;
- MongoDB: queries incluem `tenantId`;
- unicidade de mensagens: `(tenantId, externalMessageId)`;
- body/header divergentes são rejeitados.

### Knowledge Service

- índice físico: `faq_chunks-{uuid-canônico}`;
- não existe normalização com perda ou colisão de caracteres;
- diretório de ingestão é tenant-scoped;
- reindexação exige identidade interna e tenant assinado.

### PostgreSQL

- Inbox: `(tenant_id, message_id)`;
- estado: `(tenant_id, conversation_id)`;
- Outbox: `(tenant_id, idempotency_key)`;
- simulação: `(tenant_id, operation, idempotency_key)`;
- Audit/Handoff: `(tenant_id, idempotency_key)`.

## 5. Integridade e durabilidade

### 5.1 Entrada

- o BFF responde ao provedor somente após confirmação Kafka;
- o consumer usa commit manual;
- retry e DLQ precisam ser confirmados antes do commit do registro original;
- poison messages não entram em loop infinito.

### 5.2 Estado e efeitos

O Orchestrator conclui o Inbox somente depois de uma transação que:

1. atualiza o estado com versão otimista;
2. registra todos os efeitos na Outbox;
3. conclui o Inbox.

Falha de canal, memória, auditoria, handoff ou Kafka após essa transação não perde a obrigação: o dispatcher mantém o efeito como `failed` e tenta novamente.

### 5.3 Deduplicação dos efeitos

- resposta outbound: Redis, por tenant e chave da Outbox;
- histórico: índice MongoDB tenant-scoped;
- Audit/Handoff: índice PostgreSQL tenant-scoped;
- simulação: resposta persistida por chave e hash do request;
- confirmação: chave ligada à mensagem de confirmação e simulação.

## 6. Ordenação da jornada

- somente uma mensagem por conversa mantém lease de processamento;
- a atualização exige a versão esperada;
- mensagens anteriores ao último `(receivedAt, messageId)` aplicado são classificadas como atrasadas;
- efeitos carregam `journey_version`;
- uma versão posterior não é entregue enquanto existir efeito anterior não publicado.

Isso evita que retry em outro tópico avance a máquina de estados fora de ordem.

## 7. Policy de tools

O Tool Service usa allowlist por estágio.

Controles críticos:

- `simular_proposta` somente após seleção/elegibilidade do contrato;
- `confirmar_acordo` somente em `ProposalSelected` ou `ConfirmationPending`;
- confirmação exige evidência explícita ligada à mensagem atual;
- apenas o Agent Runtime pode executar as tools governadas;
- o Renegotiation Service valida a mesma decisão novamente.

A policy é código determinístico, não prompt.

## 8. Idempotência da simulação

O Renegotiation Service persiste request hash e resposta.

- chave nova: executa uma vez;
- chave concluída: retorna a resposta persistida;
- mesma chave com outro request: conflito;
- chave `processing` ou `failed`: falha fechada.

O comportamento fail-closed existe porque o Core mock ainda não valida a chave. Não há retry automático de uma execução ambígua; é necessária reconciliação administrativa.

## 9. PII e logging

Implementado:

- eventos de tools não incluem argumentos;
- métricas não usam tenant, conversation ID, CPF ou conteúdo como label;
- reason de handoff é normalizado para vocabulário fechado;
- logs operacionais usam identificadores e trace, não o texto completo.

Ainda necessário:

- redaction centralizada;
- classificação de campos e DLP;
- política de retenção e descarte;
- processo LGPD de acesso, correção e exclusão;
- criptografia em repouso gerenciada.

## 10. Segredos e infraestrutura

O segredo JWT não é versionado e o Compose falha quando ele não é informado.

Ainda faltam:

- cofre de segredos;
- rotação e revogação por serviço;
- secret scanning obrigatório;
- Kafka TLS/SASL/ACL;
- segurança do OpenSearch;
- NetworkPolicy/service mesh;
- WAF e rate limiting;
- imagens assinadas e SBOM.

## 11. Observabilidade de segurança e consistência

Monitorar:

- falhas de autenticação e tenant mismatch;
- policy denial por tool/estágio;
- idade e quantidade de efeitos pendentes/failed;
- leases expirados;
- mensagens atrasadas;
- simulações ambíguas;
- crescimento de retry e DLQ;
- falhas de dedupe nos destinos.

Alertas ainda precisam ser provisionados; o código expõe séries, mas não instala regras operacionais completas.

## 12. Lacunas críticas restantes

1. **Core Bancário Mock:** repositório inacessível; não valida JWT, policy proof ou idempotência.
2. **Identidade:** HS256 compartilhado, sem rotação/JWKS.
3. **Handoff:** não integra plataforma humana real.
4. **Infraestrutura:** Kafka/OpenSearch/rede locais sem controles de produção.
5. **Supply chain:** sem CI obrigatório, SAST, SCA, SBOM e assinatura.
6. **LGPD:** retenção, anonimização e exclusão ainda incompletas.
7. **Evidência:** build, migração e E2E dos branches P0 ainda precisam ser executados.

## 13. Classificação

O estado implementado é uma **POC endurecida com consistência transacional e enforcement determinístico de tools**. Não deve ser classificado como production-ready bancário enquanto as lacunas acima não tiverem implementação, teste e evidência operacional.

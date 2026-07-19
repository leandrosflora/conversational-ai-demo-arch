# ADR 0005: Outbox transacional, execução governada e ordenação por conversa

## Status

**Aceito — P0 de consistência.**

## Contexto

A implementação anterior possuía Inbox persistente e idempotência em alguns destinos, mas ainda apresentava cinco riscos:

1. o Orchestrator concluía o Inbox depois de tentar side effects síncronos, mesmo quando adapters degradáveis engoliam falhas;
2. o LLM recebia todas as tools e a máquina de estados validava a transição somente depois da execução;
3. `X-Tenant-Id` não estava criptograficamente vinculado ao JWT;
4. retry em tópico separado podia permitir que uma mensagem posterior da mesma conversa avançasse antes da anterior;
5. criação de simulação não possuía idempotência durável.

## Decisão

### 1. Estado autoritativo e Outbox

O `conversation-orchestrator` mantém no PostgreSQL:

- `ops.message_inbox`, por `(tenant_id, message_id)`;
- `ops.conversation_state`, por `(tenant_id, conversation_id)`;
- `ops.orchestrator_outbox`, por `(tenant_id, idempotency_key)`.

A conclusão de uma mensagem ocorre em uma única transação:

1. valida a versão esperada da conversa;
2. atualiza estágio, intenção, versão e último evento recebido;
3. grava todos os efeitos obrigatórios na Outbox;
4. conclui o Inbox com `completion_reason=effects_persisted`.

O request HTTP não precisa aguardar os downstreams. A garantia é que os efeitos foram registrados de forma durável antes do `202`.

### 2. Entrega at-least-once com deduplicação

Um worker usa lease e `FOR UPDATE SKIP LOCKED` para entregar:

- resposta ao canal;
- projeções no Memory Service;
- auditoria;
- handoff;
- eventos Kafka de intenção e mudança de estado.

Falhas deixam o efeito como `failed`, com backoff exponencial. Os destinos deduplicam:

- canal: Redis por tenant e `Idempotency-Key`;
- memória: `(tenantId, externalMessageId)`;
- Audit/Handoff: `(tenant_id, idempotency_key)`;
- Kafka: produtor idempotente, aceitando semântica at-least-once no consumidor.

### 3. Ordenação por conversa

`ops.conversation_state` possui lease de processamento e versão otimista.

- somente uma mensagem por conversa executa o Agent Runtime por vez;
- mensagens com `(receivedAt, messageId)` anterior ou igual ao último evento aplicado são marcadas como `late_message` e não executam a jornada;
- cada efeito recebe `journey_version`;
- o dispatcher não publica efeitos de uma versão enquanto existir efeito não publicado de versão anterior da mesma conversa.

### 4. Tenant canônico e assinado

O contrato único de tenant é UUID não vazio, em formato canônico.

Chamadas internas carregam o tenant simultaneamente em:

- claim JWT `tenant_id`;
- header `X-Tenant-Id`.

O destino exige igualdade entre os dois valores. Chaves e índices de idempotência incluem tenant.

O HS256 compartilhado permanece uma limitação de POC. O desenho de produção continua exigindo workload identity ou JWT assimétrico com chaves distintas.

### 5. Policy enforcement das tools

O Orchestrator envia ao Agent Runtime contexto imutável:

- tenant;
- conversa;
- mensagem;
- estágio;
- versão;
- evidência determinística de confirmação explícita.

O Agent Runtime assina esse contexto em um JWT de uso `tool_execution` destinado ao Tool Service.

O Tool Service:

- valida caller e contexto;
- aplica allowlist de tools por estágio;
- exige confirmação explícita para `confirmar_acordo`;
- gera a `Idempotency-Key` determinística da operação;
- assina uma segunda prova `governed_tool` para o Renegotiation Service.

O Renegotiation Service repete a validação antes de simular ou confirmar. Dessa forma, uma instrução do LLM não é suficiente para autorizar uma operação transacional.

### 6. Idempotência da simulação

O Renegotiation Service persiste:

- tenant;
- operação;
- idempotency key;
- hash canônico do request;
- status;
- resposta;
- erro e lease.

Repetições concluídas devolvem a resposta persistida. Reutilização da chave com outro request retorna conflito.

Como o Core Bancário Mock ainda não valida idempotência, resultados ambíguos falham fechados: uma chave em `processing` ou `failed` não é readquirida automaticamente. Ela requer reconciliação administrativa, evitando uma segunda execução potencialmente duplicada.

## Consequências positivas

- Inbox concluído significa efeitos duravelmente registrados;
- falhas downstream não causam perda silenciosa;
- respostas, auditoria, handoff e memória suportam replay;
- operações financeiras deixam de depender somente do prompt;
- tenant passa a fazer parte da identidade assinada;
- a jornada possui controle explícito de versão e ordenação.

## Consequências negativas

- aumenta o número de estados operacionais e tabelas;
- a Outbox exige monitoramento, replay e retenção;
- um efeito permanentemente falho bloqueia versões posteriores da mesma conversa até correção ou intervenção;
- resultados ambíguos de simulação podem exigir reconciliação manual enquanto o Core não implementar idempotência;
- os PRs devem ser implantados de forma coordenada por causa dos novos claims e contratos.

## Operação

Alertas mínimos:

- crescimento de Outbox `failed`/`publishing` com lease expirado;
- idade do efeito pendente mais antigo;
- conversas com versão bloqueada por efeito anterior;
- tentativas de policy negadas;
- divergência entre tenant assinado e header;
- chaves de simulação em estado ambíguo.

## Critério de conclusão

O P0 é considerado integrado somente depois de:

1. build e testes dos nove serviços;
2. migrações aplicadas em ambiente descartável e em volume existente;
3. E2E com falha induzida de canal, Memory, Audit e Handoff;
4. E2E de mensagem atrasada e duas mensagens concorrentes;
5. tentativa de confirmar acordo em estágio proibido;
6. replay de simulação com mesma chave e conflito com parâmetros diferentes;
7. validação de isolamento entre dois tenants UUID distintos.

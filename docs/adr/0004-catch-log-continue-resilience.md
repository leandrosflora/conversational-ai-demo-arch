# ADR 0004: Tratamento classificado de falhas e degradação

## Status

**Aceito — revisado no P1.**

Esta revisão substitui a regra ampla “catch-log-continue”. Falhas são tratadas conforme impacto em durabilidade, side effects, experiência do cliente e observabilidade.

## Contexto

A plataforma combina:

- entrada durável via Kafka;
- chamadas síncronas a serviços internos;
- decisões de IA e tools;
- operações mutáveis de simulação/formalização;
- persistência de sessão, auditoria e handoff;
- eventos usados apenas para observabilidade.

Aplicar o mesmo comportamento a todas as falhas produzia dois riscos opostos:

1. **perda silenciosa**, quando uma falha crítica era engolida;
2. **duplicidade**, quando um POST mutável era repetido automaticamente.

## Decisão

### Classe A — durabilidade da entrada

Exemplos:

- publicação de `channel.webhook.received`;
- gravação do Inbox do Orchestrator;
- publicação de retry ou DLQ antes do commit do offset.

Regra:

- falha **não pode** ser engolida;
- o webhook responde `503` se a entrada não foi persistida;
- o consumer não commita o offset se retry/DLQ não foi confirmado;
- métricas e logs de erro são obrigatórios.

### Classe B — operações mutáveis de negócio

Exemplos:

- simular proposta;
- confirmar acordo;
- solicitar handoff;
- registrar auditoria.

Regra:

- retry automático de `POST`, `PUT`, `PATCH` e `DELETE` é desabilitado;
- repetição só é permitida com `Idempotency-Key` validada pelo destino;
- confirmação de acordo usa chave estável baseada na simulação;
- Audit e Handoff aplicam unicidade no PostgreSQL.

### Classe C — decisão conversacional crítica

Exemplos:

- Agent Runtime indisponível;
- OpenAI indisponível;
- baixa confiança.

Regra:

- a falha é convertida em decisão explícita de handoff;
- não é tratada como sucesso normal;
- outcome e reason devem ser medidos.

### Classe D — dependências degradáveis

Exemplos:

- Memory Service temporariamente indisponível;
- Knowledge Service indisponível;
- publicação de eventos Kafka sem consumer de negócio.

Regra:

- o adapter captura e registra a falha;
- a jornada pode continuar com estado local vazio, mensagem de indisponibilidade ou ausência do evento;
- toda degradação deve incrementar métrica de resultado/erro;
- a decisão de continuar deve estar documentada por adapter, não implícita.

### Classe E — poison messages

Exemplos:

- JSON inválido;
- payload Kafka nulo;
- falha repetida acima do limite configurado.

Regra:

- não executar retry infinito;
- preservar payload original;
- publicar em `channel.webhook.received.dlq` com motivo e origem;
- commitar o offset somente após confirmação da DLQ;
- reprocessamento da DLQ é administrativo e explícito.

## Retry

- GET/HEAD/OPTIONS podem ser repetidos com backoff limitado.
- Métodos inseguros não são repetidos automaticamente.
- Retry de mensagem Kafka é feito por tópico durável, não por loop infinito no mesmo offset.
- Limite padrão da entrada: cinco tentativas.

## Timeouts

Cada chamada deve ter timeout coerente com seu orçamento de latência. Timeout do chamador não deve marcar a operação mutável como falha definitiva quando o destino pode ter concluído; por isso operações mutáveis dependem de idempotência para reconciliação.

## Observabilidade obrigatória

Cada classe deve emitir:

- contador de sucesso/erro;
- reason ou exception type com cardinalidade controlada;
- duração para operações relevantes;
- trace distribuído;
- log estruturado com correlation/trace ID e tenant, sem PII.

## Consequências positivas

- falhas críticas deixam de ser mascaradas;
- POSTs mutáveis deixam de ser duplicados por retry automático;
- poison messages deixam de bloquear a partição indefinidamente;
- degradação fica mensurável;
- comportamento operacional é previsível por classe.

## Consequências negativas

- mais estados e tópicos precisam ser operados;
- DLQ exige procedimento de triagem/reprocessamento;
- serviços precisam carregar idempotency key, tenant e trace;
- a disponibilidade percebida pode cair quando a plataforma escolhe falhar fechado em vez de aceitar perda de dados.

## Regras de revisão

Qualquer novo downstream deve declarar no PR:

1. classe da dependência;
2. timeout;
3. política de retry;
4. estratégia de idempotência;
5. comportamento de fallback;
6. métricas e alertas;
7. tratamento de dados sensíveis.

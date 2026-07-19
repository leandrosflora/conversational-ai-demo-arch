# ADR 0004: Tratamento classificado de falhas e degradação

## Status

**Aceito — revisado pelo ADR 0005.**

A regra ampla `catch-log-continue` não é permitida para efeitos obrigatórios. Cada dependência é classificada pelo impacto em durabilidade, negócio, experiência e observabilidade.

## Classe A — durabilidade da entrada e estado

Exemplos:

- publicação de `channel.webhook.received`;
- aquisição do Inbox;
- atualização versionada da conversa;
- gravação da Outbox;
- publicação de retry/DLQ antes do commit do offset.

Regra:

- falha nunca é engolida;
- o webhook retorna `503` quando a entrada não foi persistida;
- o Orchestrator não retorna `202` sem transação de estado + Outbox;
- o consumer não commita se retry/DLQ não foi confirmado.

## Classe B — efeitos obrigatórios duráveis

Exemplos:

- resposta ao cliente;
- projeção de sessão/histórico;
- auditoria;
- solicitação de handoff;
- eventos de intenção e estado.

Regra:

- o request registra o efeito na Outbox em vez de depender da disponibilidade síncrona do destino;
- o dispatcher executa at-least-once;
- falha mantém o efeito em `failed` com backoff;
- destinos precisam deduplicar pela chave tenant-scoped;
- efeito anterior não publicado bloqueia versões posteriores da mesma conversa.

Não existe mais `catch-log-continue` que permita concluir uma mensagem sem registrar a obrigação.

## Classe C — operações mutáveis de negócio

Exemplos:

- simular proposta;
- confirmar acordo.

Regra:

- retry HTTP automático é desabilitado;
- `Idempotency-Key` é obrigatória;
- Tool Service gera a chave após policy determinística;
- Renegotiation Service valida `policy_id` assinado contra a chave;
- simulação persiste request hash e resposta;
- resultado ambíguo falha fechado e exige reconciliação enquanto o Core não validar idempotência.

## Classe D — decisão conversacional crítica

Exemplos:

- Agent Runtime indisponível;
- modelo indisponível;
- baixa confiança.

Regra:

- converter para decisão explícita de handoff;
- não tratar como sucesso automático;
- medir outcome e reason com vocabulário fechado.

## Classe E — contexto enriquecedor degradável

Exemplos:

- leitura de histórico para enriquecer o prompt;
- busca de conhecimento não transacional.

Regra:

- pode degradar para histórico vazio ou mensagem de indisponibilidade;
- não pode autorizar operação financeira por ausência de contexto;
- toda degradação precisa de métrica e log sem PII.

A projeção de memória deixou de pertencer integralmente a esta classe: sua entrega é agora um efeito durável da Outbox, embora a leitura de histórico continue degradável.

## Classe F — poison messages

Exemplos:

- JSON inválido;
- payload Kafka nulo;
- falha repetida acima do limite configurado.

Regra:

- não executar retry infinito;
- preservar o payload original;
- enviar à DLQ com motivo e origem;
- commitar somente após confirmação da DLQ;
- reprocessamento é administrativo.

## Timeouts

- cada chamada deve possuir orçamento explícito;
- timeout de operação mutável é resultado potencialmente ambíguo;
- não liberar chave idempotente automaticamente depois que uma chamada externa começou;
- reconciliação precede qualquer nova tentativa quando o destino não oferece idempotência comprovada.

## Observabilidade obrigatória

Cada classe deve expor:

- contador de sucesso/erro;
- reason ou exception type de cardinalidade controlada;
- duração;
- trace distribuído;
- tenant/correlation em logs, sem conteúdo sensível;
- idade e quantidade de efeitos pendentes quando aplicável.

## Regras de revisão

Qualquer novo downstream deve declarar:

1. classe da dependência;
2. timeout;
3. política de retry;
4. estratégia de idempotência;
5. comportamento para resultado ambíguo;
6. mecanismo de durabilidade;
7. ordenação necessária;
8. métricas e alertas;
9. tratamento de dados sensíveis.

## Relação com ADR 0005

O ADR 0005 detalha:

- transação Inbox + estado + Outbox;
- lease e versão por conversa;
- policy enforcement das tools;
- tenant assinado;
- idempotência da simulação;
- reconciliação fail-closed.

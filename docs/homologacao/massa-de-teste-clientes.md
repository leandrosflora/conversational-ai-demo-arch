# Massa de teste — Homologação do processo de renegociação

Este documento define os 10 clientes de teste usados para homologar o fluxo conversacional de
renegociação (WhatsApp → `whatsapp-bff` → `conversation-orchestrator` → `agent-runtime-renegotiation`
→ `tool-service-renegotiation` → `renegotiation-service` → `core-bancario-mock`).

Cada cliente é identificado por um CPF reservado (dígito repetido 11x), resolvido de forma
determinística em `core-bancario-mock/Program.cs` (`ScenarioFixtures.ByCpf`) — ver
`openspec/changes/validate-renegotiation-flow-scenarios/design.md` para o racional. Qualquer CPF
fora desta lista continua usando os dados genéricos que o mock sempre gerou.

O número de telefone é livre (o simulador de webhook em `postman/microservices.postman_collection.json`
aceita qualquer valor em `messages[0].from` — não é um número registrado na Meta). Use a sequência
abaixo por conveniência e rastreabilidade nos logs/transcripts.

O CPF é informado pelo próprio cliente na mensagem de texto (`text.body`), como aconteceria numa
conversa real — não vai no campo `from` do payload do webhook.

## Tabela resumo

| # | CPF | Telefone (from) | Cenário | Resultado de negócio esperado |
|---|---|---|---|---|
| 0 | `00000000000` | `5511900000000` | Cliente não encontrado | Agente informa que não localizou o CPF; não avança no fluxo |
| 1 | `11111111111` | `5511900000001` | Fluxo feliz padrão | Elegível → simulação → confirmação → documento disponível |
| 2 | `22222222222` | `5511900000002` | Múltiplos contratos e dívidas | Agente identifica 2 contratos e pergunta/lista qual renegociar |
| 3 | `33333333333` | `5511900000003` | Inelegível por inadimplência crítica | Agente explica inelegibilidade (`cliente_inadimplente_critico`); não oferece simulação |
| 4 | `44444444444` | `5511900000004` | Dívida de baixo valor / pouco atraso | Elegível; simulação oferecida normalmente mesmo com valor baixo |
| 5 | `55555555555` | `5511900000005` | Dívida alta / atraso severo | Elegível; simulação oferecida para valor e atraso altos |
| 6 | `66666666666` | `5511900000006` | Sem dívida em aberto | Agente informa que não há dívidas para renegociar |
| 7 | `77777777777` | `5511900000007` | Simulação expira antes da confirmação | Simulação é aceita; confirmação é negada (`simulation_expired`); agente reoferece nova simulação |
| 8 | `88888888888` | `5511900000008` | Documento pendente após confirmação | Confirmação é aceita; documento fica indisponível (`document_not_ready`); agente orienta a aguardar |
| 9 | `99999999999` | `5511900000009` | Parcelamento fora do range solicitado pelo cliente | Cliente pede >48x; simulação recusada (`installments_out_of_range`); agente negocia número de parcelas válido |

## Detalhamento por cenário

### 0 — `00000000000` — Cliente não encontrado
- **Dados no mock**: `GET /clients/00000000000` → `404`.
- **Script sugerido**: "Meu CPF é 00000000000, quero renegociar minha dívida."
- **Esperado**: o agente responde que não conseguiu localizar o cliente e não avança para contratos/dívidas.

### 1 — `11111111111` — Fluxo feliz padrão
- **Dados no mock**: 1 contrato (`emprestimo_pessoal`, saldo R$ 2.500,00); 1 dívida (R$ 950,00, 45 dias de atraso); elegível.
- **Script sugerido**: "Meu CPF é 11111111111, quero renegociar minha dívida." → aceitar a proposta de simulação sugerida pelo agente → confirmar o acordo.
- **Esperado**: elegibilidade positiva, simulação apresentada, confirmação bem-sucedida, link do documento disponível.

### 2 — `22222222222` — Múltiplos contratos e dívidas
- **Dados no mock**: 2 contratos — `emprestimo_pessoal` (saldo R$ 6.000,00, dívidas de R$ 1.500,00/40d e R$ 800,00/70d) e `cartao_credito` (saldo R$ 3.200,00, dívidas de R$ 900,00/20d e R$ 500,00/50d).
- **Script sugerido**: "Meu CPF é 22222222222, quero renegociar minha dívida."
- **Esperado**: o agente identifica mais de um contrato/dívida e pergunta qual o cliente quer renegociar (ou lista as opções) antes de simular.

### 3 — `33333333333` — Inelegível por inadimplência crítica
- **Dados no mock**: 1 contrato (saldo R$ 12.000,00); 1 dívida (R$ 4.000,00, 300 dias de atraso); `Eligible: false`, `Reason: cliente_inadimplente_critico`.
- **Script sugerido**: "Meu CPF é 33333333333, quero renegociar minha dívida."
- **Esperado**: o agente comunica que o cliente não está elegível para renegociação no momento e não oferece simulação.

### 4 — `44444444444` — Dívida de baixo valor / pouco atraso
- **Dados no mock**: 1 contrato `cartao_credito` (saldo R$ 300,00); 1 dívida (R$ 85,00, 5 dias de atraso); elegível.
- **Script sugerido**: "Meu CPF é 44444444444, quero renegociar minha dívida."
- **Esperado**: fluxo segue normalmente apesar do valor baixo; simulação oferecida e concluível.

### 5 — `55555555555` — Dívida alta / atraso severo
- **Dados no mock**: 1 contrato (saldo R$ 25.000,00); 1 dívida (R$ 18.500,00, 210 dias de atraso); elegível.
- **Script sugerido**: "Meu CPF é 55555555555, quero renegociar minha dívida."
- **Esperado**: fluxo segue normalmente; observar se o agente ajusta o discurso para o valor/atraso elevados sem recusar indevidamente.

### 6 — `66666666666` — Sem dívida em aberto
- **Dados no mock**: 1 contrato (saldo R$ 5.000,00); lista de dívidas vazia.
- **Script sugerido**: "Meu CPF é 66666666666, quero renegociar minha dívida."
- **Esperado**: o agente informa que não há dívidas em aberto para renegociar; não oferece simulação.

### 7 — `77777777777` — Simulação expira antes da confirmação
- **Dados no mock**: 1 contrato; 1 dívida (R$ 1.300,00, 35 dias). `POST /simulations` gera `simulationId` com o marcador `-expired`, então `POST /confirmations` é sempre negado com `simulation_expired`.
- **Script sugerido**: "Meu CPF é 77777777777, quero renegociar minha dívida." → aceitar a simulação → confirmar o acordo.
- **Esperado**: simulação é apresentada normalmente; ao confirmar, o agente recebe negativa por expiração e deve informar o cliente e oferecer gerar uma nova simulação (não travar a conversa).

### 8 — `88888888888` — Documento pendente após confirmação
- **Dados no mock**: 1 contrato `cartao_credito` (saldo R$ 3.500,00); 1 dívida (R$ 2.100,00, 50 dias). `POST /confirmations` é aceito, mas o `agreementId` gerado carrega o marcador `-pendente`, então `GET /agreements/{id}/document` responde `document_not_ready`.
- **Script sugerido**: "Meu CPF é 88888888888, quero renegociar minha dívida." → aceitar a simulação → confirmar o acordo.
- **Esperado**: acordo confirmado com sucesso; ao buscar o documento, o agente informa que ele ainda está sendo gerado e orienta o cliente a aguardar, sem reportar erro.

### 9 — `99999999999` — Parcelamento fora do range solicitado pelo cliente
- **Dados no mock**: 1 contrato; 1 dívida (R$ 1.000,00, 25 dias); elegível. Este cenário não depende de dado fixo por CPF — qualquer simulação com `installments > 48` ou `<= 0` é recusada pelo mock (`installments_out_of_range`); o CPF reservado existe só para ter uma linha própria e reprodutível na massa de teste.
- **Script sugerido**: "Meu CPF é 99999999999, quero renegociar minha dívida em 60 vezes."
- **Esperado**: o agente informa que 60 parcelas não é possível e negocia um número de parcelas dentro do limite permitido (até 48).

## Cliente extra para teste manual via WhatsApp real

Além dos 10 cenários reservados (dígito repetido), existe um cliente adicional para testes manuais
feitos de um número de WhatsApp real (via ngrok), onde o `from` não é escolhido livremente:

| CPF | Cenário | Dados no mock |
|---|---|---|
| `12345678911` | Fluxo feliz padrão (manual) | 1 contrato `emprestimo_pessoal` (saldo R$ 3.000,00), 1 dívida (R$ 1.200,00, 40 dias de atraso), elegível |

**Script sugerido**: "Meu CPF é 12345678911, quero renegociar minha dívida."

## Como usar

1. Suba o stack local completo conforme `docs/runbook.md` § 4, com `MOCK_AGENT_ENABLED=false` e um `OPENAI_API_KEY` válido (ver `renegotiation-flow-homologation` capability).
2. Para cada linha da tabela resumo, envie o script sugerido via `POST /webhooks/whatsapp` assinado (helper do Postman usado na validação e2e anterior), usando o `from` da tabela.
3. Registre a transcrição da resposta e o resultado observado em
   `docs/validation/<data>-renegotiation-scenario-homologation.md`, comparando com o "resultado de
   negócio esperado" desta tabela.

# C4 Model — Nível 1 (System Context)

## Objetivo

Este documento descreve a visão de contexto da Plataforma de IA Conversacional, identificando os principais atores, sistemas externos e integrações envolvidas na jornada de renegociação de dívidas.

A plataforma atua como um canal digital inteligente capaz de conduzir negociações de forma autônoma, utilizando Inteligência Artificial Generativa, integração com sistemas corporativos e bases de conhecimento institucionais.

---

## Escopo do Sistema

O sistema sob análise é a **Plataforma de IA Conversacional**, responsável por:

- Receber mensagens dos clientes.
- Conduzir jornadas de renegociação.
- Consultar informações corporativas.
- Executar ações em sistemas internos.
- Formalizar acordos.
- Registrar auditoria das interações.
- Transferir atendimentos para operadores humanos quando necessário.

---

## Atores

### Cliente

Consumidor que interage com o banco através do WhatsApp para consultar débitos, esclarecer dúvidas, simular propostas e formalizar acordos de renegociação.

#### Responsabilidades

- Iniciar ou responder conversas.
- Validar sua identidade.
- Solicitar simulações.
- Aceitar ou rejeitar propostas.
- Formalizar acordos.

---

### Atendente Humano

Responsável por assumir conversas transferidas pela plataforma em situações que exijam intervenção manual.

#### Responsabilidades

- Tratar exceções.
- Esclarecer dúvidas complexas.
- Concluir negociações não resolvidas pela IA.

---

### Gestor de Cobrança

Responsável pelo acompanhamento dos indicadores de recuperação de crédito.

#### Responsabilidades

- Monitorar resultados.
- Acompanhar campanhas.
- Avaliar indicadores de conversão.

---

## Sistema Principal

### Plataforma de IA Conversacional

Sistema responsável por orquestrar jornadas de atendimento e renegociação utilizando agentes de IA, bases de conhecimento corporativas e integrações com sistemas bancários.

#### Principais Capacidades

- Atendimento conversacional.
- Agentes autônomos.
- Recuperação de conhecimento (RAG).
- Integrações corporativas via MCP.
- Simulação de propostas.
- Formalização de acordos.
- Auditoria.
- Human Handoff.
- Observabilidade ponta a ponta.

---

## Sistemas Externos

### WhatsApp BSP

Fornecedor responsável pela comunicação entre o WhatsApp e a Plataforma de IA Conversacional.

#### Responsabilidades

- Receber mensagens dos clientes.
- Encaminhar mensagens para a plataforma.
- Entregar respostas aos clientes.

#### Relacionamento

```text
Cliente ↔ WhatsApp BSP ↔ Plataforma de IA Conversacional
```

---

### Plataforma de Atendimento

Sistema responsável pelo atendimento humano.

#### Responsabilidades

- Receber transferências de conversas.
- Disponibilizar operadores humanos.
- Registrar atendimentos humanos.

#### Relacionamento

```text
Plataforma de IA Conversacional ↔ Plataforma de Atendimento
```

---

### Core Bancário

Conjunto de sistemas responsáveis pelas operações financeiras da instituição.

#### Responsabilidades

- Consulta de clientes.
- Consulta de contratos.
- Consulta de débitos.
- Validação de elegibilidade.
- Simulação de renegociação.
- Formalização de acordos.
- Geração de documentos.

#### Relacionamento

```text
Plataforma de IA Conversacional ↔ Core Bancário
```

---

### Base de Conhecimento Corporativa

Repositório de informações institucionais utilizado durante as interações.

#### Conteúdo

- FAQ.
- Produtos.
- Políticas.
- Procedimentos.
- Regras de negócio.

#### Relacionamento

```text
Plataforma de IA Conversacional ↔ Base de Conhecimento Corporativa
```

---

### Amazon Bedrock

Serviço de IA Generativa utilizado pela plataforma.

#### Responsabilidades

- Inferência de modelos.
- Geração de respostas.
- Classificação de intenções.
- Planejamento de ações dos agentes.

#### Relacionamento

```text
Plataforma de IA Conversacional ↔ Amazon Bedrock
```

---

### OpenSearch

Motor de busca semântica utilizado para recuperação de conhecimento.

#### Responsabilidades

- Armazenamento vetorial.
- Busca semântica.
- Recuperação de contexto.

#### Relacionamento

```text
Plataforma de IA Conversacional ↔ OpenSearch
```

---

### Salesforce CRM

Sistema corporativo responsável pela origem da base de clientes elegíveis para campanhas de renegociação.

Neste contexto, o Salesforce não possui integração direta com a Plataforma de IA Conversacional. Ele disponibiliza informações de campanha para o Data Lake corporativo, que poderá ser consumido por produtos de dados e automações de comunicação.

#### Responsabilidades

- Gerar base de clientes elegíveis para campanhas.
- Segmentar clientes para renegociação.
- Disponibilizar dados comerciais e cadastrais para o Data Lake.

#### Relacionamento

```text
Salesforce CRM → Data Lake Corporativo
```

---

### Data Lake Corporativo

Repositório corporativo utilizado para armazenamento histórico, analytics, auditoria e compartilhamento de dados entre sistemas.

#### Responsabilidades

- Receber bases de campanha vindas do Salesforce CRM.
- Armazenar dados históricos.
- Disponibilizar dados para produtos de dados.
- Apoiar indicadores operacionais e analíticos.
- Receber registros de auditoria e eventos relevantes da plataforma.

#### Relacionamento

```text
Salesforce CRM → Data Lake Corporativo
Plataforma de IA Conversacional → Data Lake Corporativo
Data Lake Corporativo → Produto de Dados / Automação de Campanha
```

---

### Produto de Dados / Automação de Campanha

Componente responsável por consumir bases de campanha disponibilizadas no Data Lake e acionar comunicações para clientes elegíveis.

#### Responsabilidades

- Consumir bases de clientes elegíveis.
- Aplicar regras de ativação de campanha.
- Enviar comunicações por Email, SMS ou outros canais externos.
- Direcionar clientes para o WhatsApp oficial do banco.

#### Relacionamento

```text
Data Lake Corporativo → Produto de Dados / Automação de Campanha → Cliente
```

---

## Diagrama Conceitual

```text
┌────────────────┐
│ Salesforce CRM │
└───────┬────────┘
        │
        ▼
┌───────────────────────┐
│ Data Lake Corporativo │
└───────┬───────────────┘
        │
        ▼
┌──────────────────────────────┐
│ Produto de Dados /           │
│ Automação de Campanha        │
└───────┬──────────────────────┘
        │ Email / SMS / Social
        ▼
┌───────────────┐
│    Cliente    │
└───────┬───────┘
        │ WhatsApp
        ▼
┌──────────────────┐
│  WhatsApp BSP    │
└────────┬─────────┘
         │
         ▼
┌────────────────────────────────────┐
│ Plataforma de IA Conversacional    │
└─────────────┬──────────────────────┘
              │
   ┌──────────┼──────────┬──────────────┬──────────────┬──────────────┐
   │          │          │              │              │              │
   ▼          ▼          ▼              ▼              ▼              ▼

Core      Bedrock   OpenSearch   Base de      Plataforma     Data Lake
Bancário             Vetorial   Conhecimento Atendimento    Corporativo
```

---

## Principais Fluxos

### Fluxo de Entrada por Campanha

1. Salesforce CRM gera uma base de clientes elegíveis.
2. A base é disponibilizada no Data Lake corporativo.
3. Um produto de dados ou automação de campanha consome essa base.
4. O cliente recebe uma comunicação por Email, SMS ou outro canal de ativação.
5. A comunicação direciona o cliente para o WhatsApp oficial do banco.
6. O cliente inicia a conversa pelo WhatsApp.
7. O WhatsApp BSP encaminha a mensagem para a Plataforma de IA Conversacional.
8. A plataforma inicia a jornada de identificação, consulta de débitos e renegociação.

---

### Fluxo de Renegociação

1. Cliente envia mensagem pelo WhatsApp.
2. WhatsApp BSP encaminha a mensagem para a plataforma.
3. A plataforma identifica e valida o cliente.
4. A plataforma consulta débitos e elegibilidade no Core Bancário.
5. O agente consulta a base de conhecimento quando necessário.
6. O agente simula propostas de renegociação.
7. O cliente aceita uma proposta.
8. O acordo é formalizado junto ao Core Bancário.
9. A confirmação é enviada ao cliente.
10. Os eventos são registrados para auditoria, rastreabilidade e observabilidade.

---

### Fluxo de Handoff Humano

1. A plataforma identifica necessidade de intervenção humana.
2. A conversa é resumida pelo agente.
3. O histórico relevante é enviado para a Plataforma de Atendimento.
4. Um atendente humano assume a conversa.
5. A plataforma registra o evento de transferência para auditoria.

---

## Premissas Arquiteturais

- O canal inicial será WhatsApp.
- A solução deve ser agnóstica ao canal.
- Salesforce CRM não se integra diretamente à Plataforma de IA Conversacional.
- Salesforce CRM disponibiliza bases de campanha no Data Lake corporativo.
- Produtos de dados ou automações de campanha consomem o Data Lake para ativação de clientes.
- A IA deve operar com grounding através de RAG.
- Todas as ações corporativas devem ocorrer por ferramentas controladas.
- A plataforma deve permitir transferência para atendimento humano.
- Todas as interações devem ser auditáveis.
- A arquitetura deve suportar evolução para múltiplos agentes especializados.
- A solução deve ser executada em ambiente Kubernetes utilizando serviços desacoplados.

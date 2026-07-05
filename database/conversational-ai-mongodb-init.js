// Conversational AI Demo Architecture MongoDB initialization script
// Use this file to recreate local MongoDB collections from an empty volume.
// Scope: flexible/high-volume data for messages, LLM runs, MCP/tool calls, RAG retrievals, memory, webhooks and evaluations.

const databaseName = 'conversational_ai';
const appUser = 'conversational_ai_app';
const appPassword = 'conversational_ai_app';

const targetDb = db.getSiblingDB(databaseName);

// ============================================================================
// Application user
// ============================================================================

if (!targetDb.getUser(appUser)) {
  targetDb.createUser({
    user: appUser,
    pwd: appPassword,
    roles: [{ role: 'readWrite', db: databaseName }]
  });
}

// ============================================================================
// Collections
// ============================================================================

const collections = [
  'conversation_messages',
  'llm_runs',
  'tool_calls',
  'rag_retrievals',
  'agent_memory',
  'channel_webhooks',
  'evaluation_runs',
  'document_chunks'
];

collections.forEach((collectionName) => {
  if (!targetDb.getCollectionNames().includes(collectionName)) {
    targetDb.createCollection(collectionName);
  }
});

// ============================================================================
// Indexes
// ============================================================================

targetDb.conversation_messages.createIndex({ tenantId: 1, conversationId: 1, createdAt: 1 });
targetDb.conversation_messages.createIndex({ tenantId: 1, userId: 1, createdAt: -1 });
targetDb.conversation_messages.createIndex({ externalMessageId: 1 }, { unique: true, sparse: true });
targetDb.conversation_messages.createIndex({ correlationId: 1 }, { sparse: true });
targetDb.conversation_messages.createIndex({ traceId: 1 }, { sparse: true });

targetDb.llm_runs.createIndex({ tenantId: 1, conversationId: 1, createdAt: -1 });
targetDb.llm_runs.createIndex({ tenantId: 1, provider: 1, model: 1, createdAt: -1 });
targetDb.llm_runs.createIndex({ correlationId: 1 }, { sparse: true });
targetDb.llm_runs.createIndex({ traceId: 1 }, { sparse: true });

targetDb.tool_calls.createIndex({ tenantId: 1, conversationId: 1, createdAt: -1 });
targetDb.tool_calls.createIndex({ tenantId: 1, toolName: 1, status: 1, createdAt: -1 });
targetDb.tool_calls.createIndex({ correlationId: 1 }, { sparse: true });
targetDb.tool_calls.createIndex({ traceId: 1 }, { sparse: true });

targetDb.rag_retrievals.createIndex({ tenantId: 1, conversationId: 1, createdAt: -1 });
targetDb.rag_retrievals.createIndex({ tenantId: 1, knowledgeBaseId: 1, createdAt: -1 });

targetDb.agent_memory.createIndex({ tenantId: 1, userId: 1, memoryType: 1 });
targetDb.agent_memory.createIndex({ expiresAt: 1 }, { expireAfterSeconds: 0, sparse: true });

targetDb.channel_webhooks.createIndex({ tenantId: 1, channel: 1, receivedAt: -1 });
targetDb.channel_webhooks.createIndex({ externalMessageId: 1 }, { unique: true, sparse: true });
targetDb.channel_webhooks.createIndex({ processed: 1, receivedAt: 1 });

targetDb.evaluation_runs.createIndex({ tenantId: 1, agentVersionId: 1, createdAt: -1 });
targetDb.evaluation_runs.createIndex({ tenantId: 1, status: 1, createdAt: -1 });

targetDb.document_chunks.createIndex({ tenantId: 1, knowledgeBaseId: 1, documentId: 1, chunkIndex: 1 });
targetDb.document_chunks.createIndex({ tenantId: 1, sourceUri: 1 });
targetDb.document_chunks.createIndex({ contentHash: 1 }, { sparse: true });

// Optional Atlas/Search-compatible vector index must be created outside local MongoDB when using Atlas Vector Search.
// For local demos, embeddings are stored here and can be replaced by OpenSearch, pgvector or Atlas later.

// ============================================================================
// Seed data
// ============================================================================

const tenantId = '00000000-0000-0000-0000-000000000001';
const userId = '20000000-0000-0000-0000-000000000001';
const conversationId = '70000000-0000-0000-0000-000000000001';
const agentVersionId = '41000000-0000-0000-0000-000000000001';
const knowledgeBaseId = '60000000-0000-0000-0000-000000000001';
const documentId = '61000000-0000-0000-0000-000000000001';
const correlationId = '80000000-0000-0000-0000-000000000001';
const traceId = 'trace-demo-001';

const now = new Date();

if (targetDb.conversation_messages.countDocuments({ conversationId }) === 0) {
  targetDb.conversation_messages.insertMany([
    {
      tenantId,
      conversationId,
      userId,
      channel: 'whatsapp',
      provider: 'meta',
      externalMessageId: 'wamid.demo.message.001',
      role: 'user',
      content: {
        text: 'Olá, quero saber como funciona o atendimento digital.',
        attachments: [],
        rawPayload: {
          from: '+5511999999999',
          type: 'text'
        }
      },
      metadata: {
        locale: 'pt-BR',
        tokenCount: 12,
        piiRedacted: true
      },
      correlationId,
      traceId,
      createdAt: now
    },
    {
      tenantId,
      conversationId,
      userId,
      channel: 'whatsapp',
      provider: 'meta',
      externalMessageId: 'wamid.demo.message.002',
      role: 'assistant',
      content: {
        text: 'O atendimento digital funciona 24x7. Posso consultar informações, responder dúvidas e acionar sistemas internos quando necessário.',
        attachments: [],
        rawPayload: {}
      },
      metadata: {
        locale: 'pt-BR',
        tokenCount: 31,
        model: 'gpt-4.1-mini'
      },
      correlationId,
      traceId,
      createdAt: new Date(now.getTime() + 1000)
    }
  ]);
}

if (targetDb.llm_runs.countDocuments({ conversationId }) === 0) {
  targetDb.llm_runs.insertOne({
    tenantId,
    conversationId,
    agentVersionId,
    provider: 'openai',
    model: 'gpt-4.1-mini',
    operation: 'chat_completion',
    input: {
      messages: [
        { role: 'system', contentRef: 'postgres:ai.prompt_templates/30000000-0000-0000-0000-000000000001' },
        { role: 'user', content: 'Olá, quero saber como funciona o atendimento digital.' }
      ]
    },
    output: {
      message: 'O atendimento digital funciona 24x7. Posso consultar informações, responder dúvidas e acionar sistemas internos quando necessário.',
      finishReason: 'stop'
    },
    usage: {
      inputTokens: 96,
      outputTokens: 31,
      totalTokens: 127
    },
    latencyMs: 840,
    status: 'success',
    error: null,
    correlationId,
    traceId,
    createdAt: now
  });
}

if (targetDb.tool_calls.countDocuments({ conversationId }) === 0) {
  targetDb.tool_calls.insertOne({
    tenantId,
    conversationId,
    agentVersionId,
    toolName: 'lookup_customer_by_phone',
    toolType: 'mcp',
    mcpServerId: '50000000-0000-0000-0000-000000000001',
    input: {
      phone: '+5511999999999'
    },
    output: {
      customerId: userId,
      status: 'active'
    },
    status: 'success',
    latencyMs: 210,
    correlationId,
    traceId,
    createdAt: now
  });
}

if (targetDb.rag_retrievals.countDocuments({ conversationId }) === 0) {
  targetDb.rag_retrievals.insertOne({
    tenantId,
    conversationId,
    knowledgeBaseId,
    query: 'como funciona atendimento digital',
    retrievedChunks: [
      {
        documentId,
        chunkId: 'faq-atendimento-geral-0001',
        score: 0.89,
        textPreview: 'Atendimento digital disponível 24x7. Para assuntos sensíveis, o agente deve validar identidade e acionar ferramenta corporativa.'
      }
    ],
    metadata: {
      strategy: 'semantic-search',
      topK: 3,
      minScore: 0.70
    },
    correlationId,
    traceId,
    createdAt: now
  });
}

if (targetDb.agent_memory.countDocuments({ tenantId, userId }) === 0) {
  targetDb.agent_memory.insertOne({
    tenantId,
    userId,
    memoryType: 'session',
    facts: [
      { key: 'preferred_language', value: 'pt-BR', confidence: 1.0 },
      { key: 'preferred_channel', value: 'whatsapp', confidence: 1.0 }
    ],
    sourceConversationId: conversationId,
    expiresAt: new Date(now.getTime() + 1000 * 60 * 60 * 24),
    createdAt: now,
    updatedAt: now
  });
}

if (targetDb.channel_webhooks.countDocuments({ externalMessageId: 'wamid.demo.message.001' }) === 0) {
  targetDb.channel_webhooks.insertOne({
    tenantId,
    channel: 'whatsapp',
    provider: 'meta',
    externalMessageId: 'wamid.demo.message.001',
    payload: {
      object: 'whatsapp_business_account',
      entry: [
        {
          changes: [
            {
              value: {
                messages: [
                  {
                    from: '+5511999999999',
                    id: 'wamid.demo.message.001',
                    type: 'text',
                    text: { body: 'Olá, quero saber como funciona o atendimento digital.' }
                  }
                ]
              }
            }
          ]
        }
      ]
    },
    processed: true,
    processedAt: now,
    receivedAt: now,
    correlationId,
    traceId
  });
}

if (targetDb.document_chunks.countDocuments({ documentId }) === 0) {
  targetDb.document_chunks.insertOne({
    tenantId,
    knowledgeBaseId,
    documentId,
    sourceUri: 'seed://faq/atendimento-geral',
    chunkId: 'faq-atendimento-geral-0001',
    chunkIndex: 0,
    text: 'Atendimento digital disponível 24x7. Para assuntos sensíveis, o agente deve validar identidade e acionar ferramenta corporativa.',
    embedding: [],
    tokenCount: 48,
    contentHash: 'faq-atendimento-geral-v1',
    metadata: {
      language: 'pt-BR',
      classification: 'internal'
    },
    createdAt: now
  });
}

if (targetDb.evaluation_runs.countDocuments({ tenantId, agentVersionId }) === 0) {
  targetDb.evaluation_runs.insertOne({
    tenantId,
    agentVersionId,
    name: 'smoke-test-local-agent',
    status: 'completed',
    dataset: 'seed://eval/smoke-test',
    metrics: {
      answerRelevance: 0.92,
      groundedness: 0.88,
      toolUseAccuracy: 0.95
    },
    cases: [
      {
        input: 'Como funciona o atendimento digital?',
        expectedBehavior: 'Responder com disponibilidade 24x7 e possibilidade de acionar sistemas internos.',
        passed: true
      }
    ],
    createdAt: now,
    completedAt: now
  });
}

print(`MongoDB initialization completed for database: ${databaseName}`);

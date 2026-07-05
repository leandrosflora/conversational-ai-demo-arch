-- Conversational AI Demo Architecture PostgreSQL initialization script
-- Use this file to recreate the local PostgreSQL database from an empty volume.
-- Scope: canonical relational model for tenants, channels, users, agents, MCP/tools, RAG metadata, conversations, integrations and outbox.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================================
-- Schemas
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS identity;
CREATE SCHEMA IF NOT EXISTS conversation;
CREATE SCHEMA IF NOT EXISTS ai;
CREATE SCHEMA IF NOT EXISTS knowledge;
CREATE SCHEMA IF NOT EXISTS integration;
CREATE SCHEMA IF NOT EXISTS ops;

-- ============================================================================
-- Identity / tenant model
-- ============================================================================

CREATE TABLE IF NOT EXISTS identity.tenants (
    tenant_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    status text NOT NULL DEFAULT 'active',
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS identity.users (
    user_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES identity.tenants(tenant_id) ON DELETE CASCADE,
    external_id text,
    display_name text,
    document_hash text,
    email_hash text,
    phone_hash text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, external_id)
);

CREATE TABLE IF NOT EXISTS identity.channels (
    channel_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES identity.tenants(tenant_id) ON DELETE CASCADE,
    channel_type text NOT NULL, -- whatsapp, web, app, api
    provider text NOT NULL, -- meta, blip, custom
    external_account_id text,
    config jsonb NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'active',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, channel_type, provider, external_account_id)
);

-- ============================================================================
-- AI agent configuration
-- ============================================================================

CREATE TABLE IF NOT EXISTS ai.prompt_templates (
    prompt_template_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES identity.tenants(tenant_id) ON DELETE CASCADE,
    name text NOT NULL,
    template_type text NOT NULL, -- system, guardrail, tool, evaluator
    content text NOT NULL,
    version text NOT NULL DEFAULT '1.0.0',
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name, version)
);

CREATE TABLE IF NOT EXISTS ai.agents (
    agent_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES identity.tenants(tenant_id) ON DELETE CASCADE,
    name text NOT NULL,
    description text,
    business_capability text,
    status text NOT NULL DEFAULT 'active',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name)
);

CREATE TABLE IF NOT EXISTS ai.agent_versions (
    agent_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id uuid NOT NULL REFERENCES ai.agents(agent_id) ON DELETE CASCADE,
    version text NOT NULL,
    model_provider text NOT NULL,
    model_name text NOT NULL,
    system_prompt_template_id uuid REFERENCES ai.prompt_templates(prompt_template_id),
    temperature numeric(3,2) NOT NULL DEFAULT 0.20 CHECK (temperature >= 0 AND temperature <= 2),
    max_output_tokens integer NOT NULL DEFAULT 2048 CHECK (max_output_tokens > 0),
    config jsonb NOT NULL DEFAULT '{}'::jsonb,
    active boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (agent_id, version)
);

CREATE TABLE IF NOT EXISTS ai.mcp_servers (
    mcp_server_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES identity.tenants(tenant_id) ON DELETE CASCADE,
    name text NOT NULL,
    base_url text NOT NULL,
    transport text NOT NULL DEFAULT 'http', -- http, sse, stdio
    auth_type text NOT NULL DEFAULT 'none',
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'active',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name)
);

CREATE TABLE IF NOT EXISTS ai.tools (
    tool_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES identity.tenants(tenant_id) ON DELETE CASCADE,
    mcp_server_id uuid REFERENCES ai.mcp_servers(mcp_server_id),
    name text NOT NULL,
    tool_type text NOT NULL, -- mcp, http_api, function
    description text,
    input_schema jsonb NOT NULL DEFAULT '{}'::jsonb,
    output_schema jsonb NOT NULL DEFAULT '{}'::jsonb,
    enabled boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name)
);

CREATE TABLE IF NOT EXISTS ai.agent_tools (
    agent_version_id uuid NOT NULL REFERENCES ai.agent_versions(agent_version_id) ON DELETE CASCADE,
    tool_id uuid NOT NULL REFERENCES ai.tools(tool_id) ON DELETE CASCADE,
    required boolean NOT NULL DEFAULT false,
    execution_order integer,
    config jsonb NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (agent_version_id, tool_id)
);

-- ============================================================================
-- Knowledge / RAG metadata
-- ============================================================================

CREATE TABLE IF NOT EXISTS knowledge.knowledge_bases (
    knowledge_base_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES identity.tenants(tenant_id) ON DELETE CASCADE,
    name text NOT NULL,
    description text,
    embedding_provider text NOT NULL,
    embedding_model text NOT NULL,
    vector_store text NOT NULL, -- mongodb_vector, opensearch, pgvector, external
    chunk_strategy jsonb NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'active',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name)
);

CREATE TABLE IF NOT EXISTS knowledge.documents (
    document_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    knowledge_base_id uuid NOT NULL REFERENCES knowledge.knowledge_bases(knowledge_base_id) ON DELETE CASCADE,
    source_type text NOT NULL, -- pdf, html, faq, api, file, url
    source_uri text NOT NULL,
    title text NOT NULL,
    content_hash text NOT NULL,
    status text NOT NULL DEFAULT 'indexed',
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    ingested_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (knowledge_base_id, source_uri, content_hash)
);

CREATE TABLE IF NOT EXISTS knowledge.document_chunks (
    chunk_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id uuid NOT NULL REFERENCES knowledge.documents(document_id) ON DELETE CASCADE,
    chunk_external_id text NOT NULL,
    chunk_index integer NOT NULL CHECK (chunk_index >= 0),
    token_count integer CHECK (token_count >= 0),
    content_preview text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (document_id, chunk_external_id)
);

-- ============================================================================
-- Conversation header / relational state
-- Full messages, LLM runs, tool calls and payloads are stored in MongoDB.
-- ============================================================================

CREATE TABLE IF NOT EXISTS conversation.conversations (
    conversation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES identity.tenants(tenant_id) ON DELETE CASCADE,
    user_id uuid REFERENCES identity.users(user_id),
    channel_id uuid NOT NULL REFERENCES identity.channels(channel_id),
    agent_version_id uuid REFERENCES ai.agent_versions(agent_version_id),
    external_thread_id text,
    status text NOT NULL DEFAULT 'open', -- open, waiting_user, escalated, closed, failed
    intent text,
    sentiment text,
    correlation_id uuid NOT NULL DEFAULT gen_random_uuid(),
    trace_id text,
    started_at timestamptz NOT NULL DEFAULT now(),
    last_message_at timestamptz,
    ended_at timestamptz,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS conversation.handoffs (
    handoff_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id uuid NOT NULL REFERENCES conversation.conversations(conversation_id) ON DELETE CASCADE,
    reason text NOT NULL,
    target_queue text NOT NULL,
    status text NOT NULL DEFAULT 'pending',
    requested_at timestamptz NOT NULL DEFAULT now(),
    accepted_at timestamptz,
    closed_at timestamptz,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS conversation.conversation_summaries (
    conversation_id uuid PRIMARY KEY REFERENCES conversation.conversations(conversation_id) ON DELETE CASCADE,
    summary text NOT NULL,
    key_facts jsonb NOT NULL DEFAULT '[]'::jsonb,
    risk_flags jsonb NOT NULL DEFAULT '[]'::jsonb,
    generated_by_agent_version_id uuid REFERENCES ai.agent_versions(agent_version_id),
    generated_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================================
-- Integrations and operational events
-- ============================================================================

CREATE TABLE IF NOT EXISTS integration.api_integrations (
    api_integration_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES identity.tenants(tenant_id) ON DELETE CASCADE,
    name text NOT NULL,
    base_url text NOT NULL,
    auth_type text NOT NULL DEFAULT 'none',
    contract jsonb NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'active',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name)
);

CREATE TABLE IF NOT EXISTS ops.outbox_events (
    outbox_event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_type text NOT NULL,
    aggregate_id uuid NOT NULL,
    event_type text NOT NULL,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'pending', -- pending, published, failed
    retry_count integer NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    correlation_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz
);

CREATE TABLE IF NOT EXISTS ops.audit_events (
    audit_event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid REFERENCES identity.tenants(tenant_id),
    actor_type text NOT NULL, -- user, system, agent, admin
    actor_id text,
    action text NOT NULL,
    resource_type text NOT NULL,
    resource_id text,
    correlation_id uuid,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================================
-- Indexes
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_users_tenant_document_hash ON identity.users (tenant_id, document_hash);
CREATE INDEX IF NOT EXISTS idx_channels_tenant_type ON identity.channels (tenant_id, channel_type);
CREATE INDEX IF NOT EXISTS idx_agent_versions_active ON ai.agent_versions (agent_id, active);
CREATE INDEX IF NOT EXISTS idx_tools_tenant_enabled ON ai.tools (tenant_id, enabled);
CREATE INDEX IF NOT EXISTS idx_documents_kb_status ON knowledge.documents (knowledge_base_id, status);
CREATE INDEX IF NOT EXISTS idx_chunks_document ON knowledge.document_chunks (document_id, chunk_index);
CREATE INDEX IF NOT EXISTS idx_conversations_tenant_status ON conversation.conversations (tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_conversations_external_thread ON conversation.conversations (channel_id, external_thread_id);
CREATE INDEX IF NOT EXISTS idx_conversations_correlation ON conversation.conversations (correlation_id);
CREATE INDEX IF NOT EXISTS idx_outbox_status_created ON ops.outbox_events (status, created_at);
CREATE INDEX IF NOT EXISTS idx_audit_tenant_created ON ops.audit_events (tenant_id, created_at DESC);

-- ============================================================================
-- Seed data
-- ============================================================================

INSERT INTO identity.tenants (tenant_id, code, name, metadata)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    'demo-bank',
    'Demo Bank',
    '{"environment":"local","purpose":"conversational-ai-demo"}'::jsonb
)
ON CONFLICT (code) DO NOTHING;

INSERT INTO identity.channels (channel_id, tenant_id, channel_type, provider, external_account_id, config)
VALUES (
    '10000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    'whatsapp',
    'meta',
    'demo-whatsapp-account',
    '{"webhookPath":"/webhooks/whatsapp","locale":"pt-BR"}'::jsonb
)
ON CONFLICT (tenant_id, channel_type, provider, external_account_id) DO NOTHING;

INSERT INTO identity.users (user_id, tenant_id, external_id, display_name, phone_hash, metadata)
VALUES (
    '20000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    'whatsapp:+5511999999999',
    'Cliente Demo',
    encode(digest('+5511999999999', 'sha256'), 'hex'),
    '{"segment":"varejo","consent":{"lgpd":true}}'::jsonb
)
ON CONFLICT (tenant_id, external_id) DO NOTHING;

INSERT INTO ai.prompt_templates (prompt_template_id, tenant_id, name, template_type, content, version, active)
VALUES (
    '30000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    'default-conversational-agent-system-prompt',
    'system',
    'Você é um assistente conversacional corporativo. Responda em pt-BR, use ferramentas quando necessário e nunca exponha dados sensíveis.',
    '1.0.0',
    true
)
ON CONFLICT (tenant_id, name, version) DO NOTHING;

INSERT INTO ai.agents (agent_id, tenant_id, name, description, business_capability)
VALUES (
    '40000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    'Customer Service Agent',
    'Agente de atendimento para WhatsApp com RAG, MCP e integração com APIs corporativas.',
    'customer-service'
)
ON CONFLICT (tenant_id, name) DO NOTHING;

INSERT INTO ai.agent_versions (agent_version_id, agent_id, version, model_provider, model_name, system_prompt_template_id, active, config)
VALUES (
    '41000000-0000-0000-0000-000000000001',
    '40000000-0000-0000-0000-000000000001',
    '1.0.0',
    'openai',
    'gpt-4.1-mini',
    '30000000-0000-0000-0000-000000000001',
    true,
    '{"guardrails":["pii-redaction","tool-allowlist"],"memory":"session"}'::jsonb
)
ON CONFLICT (agent_id, version) DO NOTHING;

INSERT INTO ai.mcp_servers (mcp_server_id, tenant_id, name, base_url, transport, auth_type, metadata)
VALUES (
    '50000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    'Customer MCP Server',
    'http://host.docker.internal:8081/mcp',
    'http',
    'bearer',
    '{"domain":"customer","owner":"platform"}'::jsonb
)
ON CONFLICT (tenant_id, name) DO NOTHING;

INSERT INTO ai.tools (tool_id, tenant_id, mcp_server_id, name, tool_type, description, input_schema, output_schema)
VALUES
(
    '51000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    '50000000-0000-0000-0000-000000000001',
    'lookup_customer_by_phone',
    'mcp',
    'Resolve cliente a partir do telefone informado pelo canal.',
    '{"type":"object","required":["phone"],"properties":{"phone":{"type":"string"}}}'::jsonb,
    '{"type":"object","properties":{"customerId":{"type":"string"},"status":{"type":"string"}}}'::jsonb
),
(
    '51000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000001',
    '50000000-0000-0000-0000-000000000001',
    'get_customer_profile',
    'mcp',
    'Consulta perfil resumido do cliente para contextualização do atendimento.',
    '{"type":"object","required":["customerId"],"properties":{"customerId":{"type":"string"}}}'::jsonb,
    '{"type":"object","properties":{"name":{"type":"string"},"segment":{"type":"string"},"flags":{"type":"array"}}}'::jsonb
)
ON CONFLICT (tenant_id, name) DO NOTHING;

INSERT INTO ai.agent_tools (agent_version_id, tool_id, required, execution_order)
VALUES
('41000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', false, 1),
('41000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000002', false, 2)
ON CONFLICT (agent_version_id, tool_id) DO NOTHING;

INSERT INTO knowledge.knowledge_bases (knowledge_base_id, tenant_id, name, description, embedding_provider, embedding_model, vector_store, chunk_strategy)
VALUES (
    '60000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    'FAQ Atendimento',
    'Base de conhecimento de atendimento para respostas via RAG.',
    'openai',
    'text-embedding-3-small',
    'mongodb_vector',
    '{"chunkSize":800,"chunkOverlap":120}'::jsonb
)
ON CONFLICT (tenant_id, name) DO NOTHING;

INSERT INTO knowledge.documents (document_id, knowledge_base_id, source_type, source_uri, title, content_hash, metadata)
VALUES (
    '61000000-0000-0000-0000-000000000001',
    '60000000-0000-0000-0000-000000000001',
    'faq',
    'seed://faq/atendimento-geral',
    'FAQ Atendimento Geral',
    encode(digest('faq-atendimento-geral-v1', 'sha256'), 'hex'),
    '{"classification":"internal","language":"pt-BR"}'::jsonb
)
ON CONFLICT (knowledge_base_id, source_uri, content_hash) DO NOTHING;

INSERT INTO knowledge.document_chunks (document_id, chunk_external_id, chunk_index, token_count, content_preview)
VALUES (
    '61000000-0000-0000-0000-000000000001',
    'faq-atendimento-geral-0001',
    0,
    48,
    'Atendimento digital disponível 24x7. Para assuntos sensíveis, o agente deve validar identidade e acionar ferramenta corporativa.'
)
ON CONFLICT (document_id, chunk_external_id) DO NOTHING;

INSERT INTO conversation.conversations (
    conversation_id,
    tenant_id,
    user_id,
    channel_id,
    agent_version_id,
    external_thread_id,
    status,
    intent,
    correlation_id,
    trace_id,
    last_message_at,
    metadata
)
VALUES (
    '70000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    '41000000-0000-0000-0000-000000000001',
    'wamid.demo.thread.001',
    'open',
    'general-support',
    '80000000-0000-0000-0000-000000000001',
    'trace-demo-001',
    now(),
    '{"source":"seed","demo":true}'::jsonb
)
ON CONFLICT (conversation_id) DO NOTHING;

INSERT INTO ops.outbox_events (aggregate_type, aggregate_id, event_type, payload, correlation_id)
VALUES (
    'conversation',
    '70000000-0000-0000-0000-000000000001',
    'conversation.started',
    '{"conversationId":"70000000-0000-0000-0000-000000000001","channel":"whatsapp"}'::jsonb,
    '80000000-0000-0000-0000-000000000001'
)
ON CONFLICT DO NOTHING;

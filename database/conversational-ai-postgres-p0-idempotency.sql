-- P0 consistency and policy migration.
-- Fresh PostgreSQL volumes execute this through docker-entrypoint-initdb.d.
-- Existing volumes are migrated idempotently by the owning services at startup.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS ops;

CREATE TABLE IF NOT EXISTS ops.message_inbox (
    tenant_id uuid NOT NULL,
    message_id text NOT NULL,
    conversation_id text NOT NULL,
    status text NOT NULL CHECK (status IN ('processing', 'completed', 'failed')),
    lease_until timestamptz,
    attempt_count integer NOT NULL DEFAULT 0,
    last_error text,
    source_received_at timestamptz,
    completion_reason text,
    received_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    PRIMARY KEY (tenant_id, message_id)
);

CREATE INDEX IF NOT EXISTS idx_message_inbox_status_lease
    ON ops.message_inbox (status, lease_until);

CREATE TABLE IF NOT EXISTS ops.conversation_state (
    tenant_id uuid NOT NULL,
    conversation_id text NOT NULL,
    journey_stage text NOT NULL,
    last_intent text,
    version bigint NOT NULL DEFAULT 0,
    last_received_at timestamptz,
    last_message_id text,
    processing_message_id text,
    processing_lease_until timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, conversation_id)
);

CREATE INDEX IF NOT EXISTS idx_conversation_state_processing_lease
    ON ops.conversation_state (processing_lease_until);

CREATE TABLE IF NOT EXISTS ops.orchestrator_outbox (
    outbox_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    message_id text NOT NULL,
    conversation_id text NOT NULL,
    journey_version bigint NOT NULL DEFAULT 0,
    effect_type text NOT NULL,
    idempotency_key text NOT NULL,
    payload jsonb NOT NULL,
    status text NOT NULL CHECK (status IN ('pending', 'publishing', 'published', 'failed')),
    attempt_count integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    locked_until timestamptz,
    last_error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz,
    UNIQUE (tenant_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_orchestrator_outbox_dispatch
    ON ops.orchestrator_outbox (status, next_attempt_at, locked_until, created_at);
CREATE INDEX IF NOT EXISTS idx_orchestrator_outbox_conversation_version
    ON ops.orchestrator_outbox (tenant_id, conversation_id, journey_version, status);

CREATE TABLE IF NOT EXISTS ops.renegotiation_idempotency (
    tenant_id uuid NOT NULL,
    operation text NOT NULL,
    idempotency_key text NOT NULL,
    request_hash text NOT NULL,
    status text NOT NULL CHECK (status IN ('processing', 'completed', 'failed')),
    response jsonb,
    lease_until timestamptz,
    attempt_count integer NOT NULL DEFAULT 0,
    last_error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    PRIMARY KEY (tenant_id, operation, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_renegotiation_idempotency_status_lease
    ON ops.renegotiation_idempotency (status, lease_until);

ALTER TABLE ops.audit_events
    ADD COLUMN IF NOT EXISTS idempotency_key text;

DROP INDEX IF EXISTS ops.ux_audit_events_idempotency_key;
CREATE UNIQUE INDEX IF NOT EXISTS ux_audit_events_tenant_idempotency_key
    ON ops.audit_events (tenant_id, idempotency_key);

ALTER TABLE conversation.handoffs
    ADD COLUMN IF NOT EXISTS tenant_id uuid;
ALTER TABLE conversation.handoffs
    ADD COLUMN IF NOT EXISTS idempotency_key text;

DROP INDEX IF EXISTS conversation.ux_handoffs_idempotency_key;
CREATE UNIQUE INDEX IF NOT EXISTS ux_handoffs_tenant_idempotency_key
    ON conversation.handoffs (tenant_id, idempotency_key);
CREATE INDEX IF NOT EXISTS idx_handoffs_tenant_status_requested
    ON conversation.handoffs (tenant_id, status, requested_at DESC);

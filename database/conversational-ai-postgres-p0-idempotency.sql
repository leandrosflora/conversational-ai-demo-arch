-- P0 reliability migration.
-- Fresh PostgreSQL volumes execute this through docker-entrypoint-initdb.d.
-- Existing volumes are migrated lazily by the three owning services at startup/request time.

CREATE SCHEMA IF NOT EXISTS ops;

CREATE TABLE IF NOT EXISTS ops.message_inbox (
    message_id text PRIMARY KEY,
    conversation_id text NOT NULL,
    status text NOT NULL CHECK (status IN ('processing', 'completed', 'failed')),
    lease_until timestamptz,
    attempt_count integer NOT NULL DEFAULT 0,
    last_error text,
    received_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_message_inbox_status_lease
    ON ops.message_inbox (status, lease_until);

ALTER TABLE ops.audit_events
    ADD COLUMN IF NOT EXISTS idempotency_key text;

CREATE UNIQUE INDEX IF NOT EXISTS ux_audit_events_idempotency_key
    ON ops.audit_events (idempotency_key);

ALTER TABLE conversation.handoffs
    ADD COLUMN IF NOT EXISTS idempotency_key text;

CREATE UNIQUE INDEX IF NOT EXISTS ux_handoffs_idempotency_key
    ON conversation.handoffs (idempotency_key);

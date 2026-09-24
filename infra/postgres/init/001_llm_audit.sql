-- LLM classifier audit schema (design docs/design/llm-classifier-v1.md, D5-3).
-- Executed once by the postgres image on first start of an empty data volume.

CREATE TABLE llm_audit (
    id             bigserial PRIMARY KEY,
    ticket_id      text        NOT NULL,
    run_id         text,
    job_type       text        NOT NULL,
    model          text        NOT NULL,
    prompt_version text        NOT NULL,
    input_hash     text,
    output         jsonb,
    confidence     numeric(4,3),
    needs_review   boolean,
    fallback_used  boolean,
    tokens_in      int,
    tokens_out     int,
    latency_ms     int,
    created_at     timestamptz DEFAULT now()
);

CREATE INDEX llm_audit_ticket_run_idx ON llm_audit (ticket_id, run_id);
CREATE INDEX llm_audit_created_at_idx ON llm_audit (created_at);

CREATE TABLE classification_review (
    id             bigserial PRIMARY KEY,
    ticket_id      text        NOT NULL,
    run_id         text,
    reviewed_by    text,
    llm_intent     text,
    final_intent   text,
    llm_sentiment  text,
    final_sentiment text,
    escalated      boolean,
    reviewed_at    timestamptz DEFAULT now()
);

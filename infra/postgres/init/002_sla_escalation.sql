-- SLA escalation audit (Phase 6.3, design D6-5 / operations-v1.md §4). One row per
-- sla.escalate job, whatever the outcome, so every SLA breach is recorded.
--
-- Executed by the postgres image only on the first start of an EMPTY data volume. The
-- worker runs the same CREATE TABLE IF NOT EXISTS at startup (workers/llm-classifier/sla.py),
-- so an existing stand gets the table without a manual step; keep both copies identical.

CREATE TABLE IF NOT EXISTS sla_escalation (
    id                   bigserial PRIMARY KEY,
    ticket_id            text        NOT NULL,
    run_id               text,
    process_instance_key text        NOT NULL,
    user_task_key        text,
    sla_deadline         timestamptz,
    escalated_at         timestamptz NOT NULL,
    previous_priority    int,
    new_priority         int,
    outcome              text        NOT NULL,   -- escalated | already_escalated | no_open_task
    created_at           timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sla_escalation_ticket_run_idx ON sla_escalation (ticket_id, run_id);

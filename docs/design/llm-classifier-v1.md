# LLM classifier v1 — design (Phase 5)

**Status:** in progress — 5.0 (decisions) and 5.1 (infrastructure + worker skeleton) are
implemented; the LLM path lands in 5.2–5.4. Milestones with status: `docs/backlog.md`,
Phase 5 section.

Related: ADR-004 (provider), `integrations-v1.md`, `process-v1.md`,
`workers/llm-classifier/`.

## 1. Classify path

```
ticket.classify job
  → LLM (LLM_MODEL_CLASSIFY, temperature 0, JSON schema)          (5.2)
      invalid JSON → one retry with the validator error in the prompt
      still invalid / transport error → keyword fallback (rules.py) + needsReview=true
  → cross-check against keyword rules (D5-2)
  → mandatory audit row in PostgreSQL (D5-3) — failure fails the job
  → output: intent, sentiment, language, confidence, needsReview,
            classifierSource (llm | fallback), promptVersion
```

Phase 5.1 ships the skeleton: handlers still answer from `rules.py`
(`classifierSource=fallback`), the audit write is live, `llm/provider.py` is the
interface only.

## 2. Decisions

| ID | Decision | Rationale |
|---|---|---|
| D5-1 | Model routing per job type: `ticket.classify` → `claude-haiku-4-5`; `ticket.answer` / `ticket.notify` → `claude-sonnet-5`. Env: `LLM_MODEL_CLASSIFY`, `LLM_MODEL_GENERATE` (aliases). System prompts use prompt caching | Cheap where a wrong answer is caught by guardrails, better model where the output is customer-facing. Cost estimate for the phase: single-digit USD. The exact model id of every call is recorded in the audit from `response.model`, so alias drift is visible |
| D5-2 | Guardrail policy for classify: strict JSON schema (intent enum `change_booking\|cancel_refund\|question\|other`; sentiment enum; language `ru\|en\|other`; confidence 0..1; rationale one line). Temperature 0. Invalid JSON → one retry with the validator error in the prompt → still invalid → keyword fallback (`rules.py`) + `needsReview=true`. Threshold `CLASSIFY_CONFIDENCE_THRESHOLD`, initial 0.8, final value calibrated from `tests/classification/report.sh` (5.2). Cross-check: LLM intent ≠ keyword intent AND confidence < 0.9 → `needsReview=true`. Worker always outputs `classifierSource` (`llm` \| `fallback`) and `promptVersion` | The LLM is untrusted input to the process: everything it returns is validated, low confidence and disagreement route to a human, and the fallback keeps the process moving when the provider misbehaves |
| D5-3 | Audit in PostgreSQL: tables `llm_audit` and `classification_review` (§3). The audit write is mandatory — if it fails, the job fails with retries → incident in Operate. **Verified against the SDK `8.9.0.dev39` source** (`runtime/job_worker.py`): any exception in a handler callback becomes a fail-job action with `retries - 1`, so raising from the audit module is sufficient — no explicit `fail_job` call needed. The live negative test (broken `DATABASE_URL` → one ticket → incident after retries) is part of the 5.1 acceptance run | An unauditable classification must not complete silently; the deliberate incident feeds the Phase 6 incident-handling scenarios |
| D5-4 | Review loop re-routes: after `review-classification` the process goes back through `route-ticket`, so corrected intent/sentiment produce fresh `team`/`priority`/`slaDeadline`. The escalate path goes straight to `handle-by-agent` with the initial routing. Process change lands in v7 (5.3, Modeler, by the owner). D4-6 implication: the user task needs explicit output mappings for `intent`/`sentiment`/`escalate` | A corrected classification with stale routing is worse than no review; the escalate path is a human takeover where routing no longer matters |
| D5-5 | Scope of answer/notify (implemented in 5.4): `ticket.answer` = general-question branch, grounded in `prompts/kb_tourism.md`, must not state amounts/dates absent from the input. `ticket.notify` = final customer message in the customer's language built from structured variables (`resolution`, `refundAmountCustomer`, `slaDeadline`, `requiredChecks`); delivery stays a stub (log). Both on `LLM_MODEL_GENERATE` | Grounding limits hallucinated commitments; notify composes from verified process data only, so the LLM formats rather than invents |
| D5-6 | Ollama rejected: no local models on the homelab (owner decision); the provider abstraction stays (`llm/provider.py`), so a second provider is a config change. ADR-004 amended accordingly | Local hosting is an operations project of its own and outside this stand's scope |

## 3. Audit schema

`infra/postgres/init/001_llm_audit.sql`, executed on the first start of an empty
`postgres-data` volume:

- `llm_audit(id, ticket_id, run_id, job_type, model, prompt_version, input_hash,
  output jsonb, confidence numeric(4,3), needs_review, fallback_used, tokens_in,
  tokens_out, latency_ms, created_at)`; indexes on `(ticket_id, run_id)` and
  `created_at`. `model` holds the **exact id from the API response** (`response.model`),
  or the literal `fallback`; in 5.1 every row is `model='fallback'`,
  `prompt_version='rules'`, `fallback_used=true`.
- `classification_review(id, ticket_id, run_id, reviewed_by, llm_intent, final_intent,
  llm_sentiment, final_sentiment, escalated, reviewed_at)` — filled by the 5.3 review
  loop.

## 4. Configuration

| Variable | Where | Meaning |
|---|---|---|
| `DATABASE_URL` | `infra/.env` (no default; password must match `POSTGRES_PASSWORD`) | audit connection |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | `infra/.env` | database bootstrap |
| `ANTHROPIC_API_KEY` | `infra/.env` | provider key (used from 5.2) |
| `LLM_MODEL_CLASSIFY` / `LLM_MODEL_GENERATE` | `infra/.env`, defaults in compose | model aliases per D5-1 |
| `CLASSIFY_CONFIDENCE_THRESHOLD` | `infra/.env`, default 0.8 | D5-2; calibrated in 5.2 |
| `CLASSIFY_PROMPT_VERSION` | `infra/.env`, default `classify_v1` | stamped into output and audit |

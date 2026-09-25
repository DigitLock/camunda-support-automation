# LLM classifier worker (Phase 5)

One Python process serving `ticket.classify`, `review.record`, `ticket.answer` and
`ticket.notify` of `support-request-v1`. Formerly `workers/stub` (Phases 2–4); renamed in Phase 5 when the
LLM path arrived. Design and decisions: `docs/design/llm-classifier-v1.md`.

Since 5.2 `ticket.classify` runs the real LLM path: `classifier.py` orchestrates the
Claude call (`llm/provider.py`, structured output via `output_config.format`; the system
prompt carries a cache marker, but haiku-4-5's minimum cacheable prefix is 4096 tokens —
the cache activates by itself once the prompt grows past that), guardrails
(`llm/guardrails.py`: JSON schema, one validator-error retry, keyword fallback,
threshold, cross-check — D5-2/D5-7) and the mandatory audit row (`audit.py`, D5-3).
Since 5.3 `review.record` writes the outcome of the `review-classification` user task
to `classification_review` (final values from the form, LLM values from the latest
`llm_audit` row of the same ticket/run — D5-4). Since 5.4 `ticket.answer` and
`ticket.notify` generate customer text on `LLM_MODEL_GENERATE` through `generator.py`:
structured output `{text, language, usedKbIds}`, local guardrails
(`llm/generation_guardrails.py`: language, number grounding, KB ids, length — D5-9), one
retry, then the templates in `rules.py`; the answer prompt carries `prompts/kb_tourism.md`
(D5-11). Provider timeout 30 s with one SDK retry per call, job timeout 90 s for the two
generation types. Calibration: `tests/classification/report.sh`,
`tests/generation/report.sh`.

Runs as the `worker-llm-classifier` container in the `workers` compose profile (ADR-006):
built by `make deploy`, healthcheck on `:8081/healthz`, clean shutdown on SIGTERM. The
venv run below remains the dev fallback.

## Version pins

- `camunda-orchestration-sdk==8.9.0.dev39` — no stable 8.9.x on PyPI (checked 2026-09-22;
  the stable 9.x line targets server 8.10). Revisit when a stable 8.9 SDK is published.
- `psycopg[binary]==3.3.6` — audit writes (D5-3).
- `anthropic==1.8.0` — the Claude provider (D5-1); `jsonschema==4.26.0` — guardrails (D5-2).

## Install (dev fallback — venv)

```bash
cd workers/llm-classifier
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

## Configure and run

```bash
cp .env.example .env    # set CAMUNDA_PASSWORD and DATABASE_URL (see infra/.env on the stand)
set -a; source .env; set +a    # required: the worker does not read .env itself
.venv/bin/python worker.py
```

Run the worker as the stand's deploy user, never as root — root-owned files under
`workers/llm-classifier/` break `make sync` later (see the rsync error 23 entry in
`docs/ops/install.md`).

The worker long-polls the four job types and logs one line per completed job:
`job=<type> ticketId=<id> -> <returned variables>`. Stop with Ctrl-C (or SIGTERM in
compose). The SDK's own logger stays at INFO (`LOG_LEVEL` overrides) so empty-poll DEBUG
lines do not drown the job lines. A failed audit write fails the job on purpose —
retries, then an incident in Operate (D5-3).

Uses the `admin` user for now; a dedicated worker user is parked in `docs/backlog.md`
for Phase 6.

## Handlers

Pure functions in `handlers.py` (dict in → dict out, no SDK types); keyword tables and
thresholds live in `rules.py`. `classifierSource`/`promptVersion` are attached by the
worker wrapper, and the audit write happens there too — handlers stay pure. `review.record`
is database-only and lives entirely in `worker.py` + `audit.py`.

| Job type | Returns (5.2) |
|---|---|
| `ticket.classify` | LLM path: `intent`, `sentiment`, `confidence`, `needsReview`, `classifierSource` (`llm`\|`fallback`), `promptVersion`, `rationale`, `detectedLanguage` (`language` from the payload is never overwritten); on LLM failure — keyword rules + `needsReview=true` |
| `review.record` | `{}` — inserts a `classification_review` row: `reviewed_by` (`reviewedBy`, `unknown` if empty), `final_intent`/`final_sentiment`/`escalated` from the form, `llm_intent`/`llm_sentiment` from `llm_audit`; write failure fails the job (D5-3) |
| `ticket.answer` | `answerText` (grounded in the KB, reply language per D5-8), `answerSource` (`llm`\|`fallback`), `answerKbIds` (cited sections; `["KB-11"]` = handover to an agent); audit row `job_type=answer` |
| `ticket.notify` | `customerMessage`, `messageLanguage`, `notifySource` (`llm`\|`fallback`) from the LLM, plus the deterministic `notificationTemplate` = `notify-<resolution>` and `notifiedAt`; delivery is a `deliver ticketId=…` log line (D5-5); audit row `job_type=notify` |

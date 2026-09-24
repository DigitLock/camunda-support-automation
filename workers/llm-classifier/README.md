# LLM classifier worker (Phase 5)

One Python process serving `ticket.classify`, `ticket.answer` and `ticket.notify` of
`support-request-v1`. Formerly `workers/stub` (Phases 2–4); renamed in Phase 5 when the
LLM path arrived. Design and decisions: `docs/design/llm-classifier-v1.md`.

Since 5.2 `ticket.classify` runs the real LLM path: `classifier.py` orchestrates the
Claude call (`llm/provider.py`, structured output via `output_config.format`; the system
prompt carries a cache marker, but haiku-4-5's minimum cacheable prefix is 4096 tokens —
the cache activates by itself once the prompt grows past that), guardrails
(`llm/guardrails.py`: JSON schema, one validator-error retry, keyword fallback,
threshold, cross-check — D5-2/D5-7) and the mandatory audit row (`audit.py`, D5-3).
`ticket.answer` / `ticket.notify` stay deterministic until 5.4. Calibration:
`tests/classification/report.sh`.

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

The worker long-polls the three job types and logs one line per completed job:
`job=<type> ticketId=<id> -> <returned variables>`. Stop with Ctrl-C (or SIGTERM in
compose). The SDK's own logger stays at INFO (`LOG_LEVEL` overrides) so empty-poll DEBUG
lines do not drown the job lines. A failed audit write fails the job on purpose —
retries, then an incident in Operate (D5-3).

Uses the `admin` user for now; a dedicated worker user is parked in `docs/backlog.md`
for Phase 6.

## Handlers

Pure functions in `handlers.py` (dict in → dict out, no SDK types); keyword tables and
thresholds live in `rules.py`. `classifierSource`/`promptVersion` are attached by the
worker wrapper, and the audit write happens there too — handlers stay pure.

| Job type | Returns (5.2) |
|---|---|
| `ticket.classify` | LLM path: `intent`, `sentiment`, `confidence`, `needsReview`, `classifierSource` (`llm`\|`fallback`), `promptVersion`, `rationale`, `detectedLanguage` (`language` from the payload is never overwritten); on LLM failure — keyword rules + `needsReview=true` |
| `ticket.answer` | `{}` (logs only; LLM in 5.4) |
| `ticket.notify` | `notificationTemplate` = `notify-<resolution>`, `notifiedAt` (ISO 8601 UTC; LLM in 5.4) |

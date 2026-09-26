# LLM classifier v1 — design (Phase 5)

**Status:** in progress — 5.0 (decisions), 5.1 (infrastructure + worker skeleton),
5.2 (LLM classify path with guardrails), 5.3 (review loop, process v7; accepted live, run
`20260925T063333Z`) and 5.4 (LLM answer/notify, process v8; accepted live, run
`20260925T121224Z`) are done; 5.5 pending. Milestones
with status: `docs/backlog.md`, Phase 5 section.

Related: ADR-004 (provider), `integrations-v1.md`, `process-v1.md`,
`workers/llm-classifier/`.

## 1. Classify path (implemented in 5.2)

```mermaid
flowchart TD
    J[ticket.classify job] --> P["ClaudeProvider (LLM_MODEL_CLASSIFY,<br/>max_tokens 300, timeout 30s,<br/>SDK max_retries 2, cached system prompt)"]
    P -->|response text| V{JSON + schema valid?<br/>guardrails.py}
    V -- yes --> T{confidence ≥ threshold?}
    V -- "no → one retry with the<br/>validator error appended" --> P2[second call]
    P2 --> V2{valid now?}
    V2 -- yes --> T
    V2 -- "no → fallback_reason<br/>invalid_output" --> F
    P -. "provider failure: network/timeout/5xx/429<br/>after SDK retries → api_error (D5-7)" .-> F["keyword fallback (rules.py)<br/>needsReview=true, classifierSource=fallback"]
    P -. "other 4xx (our bug/config) →<br/>exception propagates" .-> I["job fails with retries →<br/>incident in Operate (D5-7)"]
    T -- no --> R[needsReview=true, reason below_threshold]
    T -- yes --> X{"cross-check: rules intent ≠ LLM intent,<br/>rules conf ≥ 0.8, LLM conf < 0.9?"}
    X -- yes --> R2[needsReview=true, reason cross_check]
    X -- no --> OK[auto-routed]
    R --> A; R2 --> A; OK --> A; F --> A
    A["mandatory audit row (D5-3) — write failure fails the job"] --> OUT["variables: intent, sentiment, confidence,<br/>needsReview, classifierSource, promptVersion,<br/>rationale, detectedLanguage"]
```

The system prompt is a versioned artifact (`prompts/classify_v2.md` currently, selected
by `CLASSIFY_PROMPT_VERSION` — see `prompts/README.md`; v2 added a confidence rubric and
a 20-word rationale cap after the v1 calibration run). The process variable `language`
(from the ticket payload) is never overwritten; the LLM's detection goes out as
`detectedLanguage`.

**Enum note:** `intent` and `sentiment` values are exactly what the DMN tables and the
`gw-intent` flows consume. The single accepted enum extension of 5.2 is `sentiment:
positive` — the DMN is untouched (its rules only test `negative`); the
review-classification form picks the value up in 5.3.

Calibration: `tests/classification/report.sh` over `tickets-40.json` (40 tourism tickets,
~50/50 RU/EN, 5 deliberately ambiguous ones that must land in review, 10 hard-but-
unambiguous ones — typos, colloquial Russian, mixed intents with a dominant one). Gates:
intent accuracy ≥ 0.85, zero silent errors (wrong intent that was not sent to review),
zero fallbacks. The final `CLASSIFY_CONFIDENCE_THRESHOLD` is fixed after the classify_v2
calibration run; `report-latest.md` is the current record, `report-classify_v1.md` the
archived v1 one.

**Threshold note (v2 calibration, runs=3, 40 tickets):** the v1 run showed flat 0.95
confidences and T-1006 oscillating 0.70–0.85 around the threshold; the v2 confidence
rubric spread the distribution into two clusters — ambiguous 0.30–0.75, confident
(including the 10 hard tickets) 0.85–0.95, with a clean 0.75–0.85 gap. The threshold
sits in that gap at **0.8**: all swept thresholds gave zero errors, so the deciding
criterion is the margin to both clusters (0.7 touches T-1006's range, 0.9 reviews
correct 0.85 answers). Re-calibrate whenever the prompt or the model changes.
Consequence for e2e stays: `send-tickets.sh` closes a `review-classification` task for
**any** ticket where one appears and verifies by final resolution — only T-1004's
review visit is a hard expectation (borderline tickets may still drift across runs).

## 2. Decisions

| ID | Decision | Rationale |
|---|---|---|
| D5-1 | Model routing per job type: `ticket.classify` → `claude-haiku-4-5`; `ticket.answer` / `ticket.notify` → `claude-sonnet-5`. Env: `LLM_MODEL_CLASSIFY`, `LLM_MODEL_GENERATE` (aliases). System prompts carry `cache_control`. The minimum cacheable prefix is model-specific: 4096 tokens for haiku-4-5, so the ~600-token classify prompt never caches (write/read 0 — the marker is harmless, do not inflate the prompt for the cache's sake); 1024 tokens for sonnet-5, so the answer prompt + KB **is** cached — the 5.4 generation report shows cache write 2433 / read 21897 tokens over 10 answers | Cheap where a wrong answer is caught by guardrails, better model where the output is customer-facing. Cost estimate for the phase: single-digit USD. The exact model id of every call is recorded in the audit from `response.model`, so alias drift is visible. Confirmed by the v2 calibration: Sonnet was never needed for classify — Haiku closed the 40-ticket set including the 10 hard ones (35/35, 0 silent); a comparison run is a config change via `LLM_MODEL_CLASSIFY`, no code involved |
| D5-2 | Guardrail policy for classify: strict JSON schema (intent enum `change_booking\|cancel_refund\|question\|other`; sentiment enum; language `ru\|en\|other`; confidence 0..1; rationale one line). The schema is enforced twice: **structured output** (`output_config.format: json_schema`, GA for claude-haiku-4-5) constrains the answer server-side — the wire copy (`API_SCHEMA`) has the keywords structured output rejects stripped (`minimum`/`maximum`/`multipleOf`, `minLength`/`maxLength`, `pattern`) — and the full-schema `jsonschema` validation in the worker stays as the second line of defence, so the confidence range and rationale length are still enforced locally (violation → invalid_output → retry → fallback). Parsing is tolerant before validation — markdown fences are stripped and the first balanced JSON object is extracted (`guardrails.extract_json`): the model's *packaging* of the answer is untrusted input like everything else it returns, so tolerating it is a guardrail, not a workaround; the schema check afterwards stays strict. No temperature parameter: the `anthropic` SDK (1.8.0) removed sampling controls from `messages.create` for current models — output discipline comes from the schema-constrained output, the validation and the retry, not from temperature. Invalid JSON → one retry with the validator error in the prompt → still invalid → keyword fallback (`rules.py`) + `needsReview=true`. Threshold `CLASSIFY_CONFIDENCE_THRESHOLD` **fixed at 0.8** (classify_v2 calibration, runs=3, 40 tickets): with zero errors at every swept threshold the choice is made by the gap between the ambiguous cluster (≤ 0.75) and the lower edge of confident answers (≥ 0.85) — 0.7 would make T-1006 (0.70–0.75) unstable, 0.9 would send correct 0.85 answers to review. Re-calibration is mandatory on any prompt or model change. Cross-check: LLM intent ≠ keyword intent AND confidence < 0.9 → `needsReview=true`. Worker always outputs `classifierSource` (`llm` \| `fallback`) and `promptVersion` | The LLM is untrusted input to the process: everything it returns is validated, low confidence and disagreement route to a human, and the fallback keeps the process moving when the provider misbehaves |
| D5-3 | Audit in PostgreSQL: tables `llm_audit` and `classification_review` (§3). The audit write is mandatory — if it fails, the job fails with retries → incident in Operate. **Verified against the SDK `8.9.0.dev39` source** (`runtime/job_worker.py`): any exception in a handler callback becomes a fail-job action with `retries - 1`, so raising from the audit module is sufficient — no explicit `fail_job` call needed. The live negative test (broken `DATABASE_URL` → one ticket → incident after retries) is part of the 5.1 acceptance run | An unauditable classification must not complete silently; the deliberate incident feeds the Phase 6 incident-handling scenarios |
| D5-4 | **Implemented in process v7 (5.3).** Review loop re-routes: after `review-classification` → `record-review` the default flow of `gw-review-exit` goes back through `route-ticket`, so corrected intent/sentiment produce fresh `team`/`priority`/`slaDeadline`; `gw-needs-review` then passes (`needsReview = false` from the task's output mapping). The escalate path goes straight to `handle-by-agent` with the initial routing. D4-6 implication, confirmed live in the 5.2 acceptance (T-1004's corrected intent stayed task-local on v6): the user task carries explicit output mappings for `intent`/`sentiment`/`escalate`/`reviewedBy`. Changelog: `process-v1.md` §11 | A corrected classification with stale routing is worse than no review; the escalate path is a human takeover where routing no longer matters |
| D5-5 | Scope of answer/notify (implemented in 5.4, §6): `ticket.answer` = general-question branch, grounded in `prompts/kb_tourism.md`, must not state amounts/dates absent from the input. `ticket.notify` = final customer message in the customer's language built from structured variables (`resolution`, `bookingRef`, `refundAmountCustomer` + `customerCurrency`, `answerText`, `slaDeadline`); delivery stays a stub (log). Both on `LLM_MODEL_GENERATE` | Grounding limits hallucinated commitments; notify composes from verified process data only, so the LLM formats rather than invents |
| D5-6 | Ollama rejected: no local models on the homelab (owner decision); the provider abstraction stays (`llm/provider.py`), so a second provider is a config change. ADR-004 amended accordingly | Local hosting is an operations project of its own and outside this stand's scope |
| D5-8 | Reply language = the payload's `language` if it is `ru`/`en`, else the classifier's `detectedLanguage` if `ru`/`en`, else `en`. Applied identically by answer and notify; the target goes into the prompt and is enforced by the guardrail (`language_mismatch`) | The payload language is the customer's declared preference; the detection is the fallback for a missing or unsupported value, and English is the desk's default |
| D5-9 | Generation guardrails: structured output `{text, language, usedKbIds[]}` (schema on the wire and locally, as D5-2), then local checks — `language` equals the D5-8 target; **every number in `text` occurs in the ticket variables the model saw or in the KB** (numeric comparison, so `320.5` = `320,50`; the digits of `bookingRef`/`ticketId` and of the KB ids `KB-01` are whitelisted, so "your booking BK-90" passes); `usedKbIds ⊆` KB ids; `text` ≤ 1200 characters. A violation → one retry with the validator message (which names the offending numbers; the log line does too) → deterministic template from `rules.py` with `answerSource`/`notifySource = fallback`. The job always completes; `needsReview` is untouched. A violation caught by the retry still fails the generation report gate | The text goes to a customer: a number that is not in the process data or the KB is an invented commitment. The template keeps the process moving, and the audit (`violations`, `fallback_reason`) makes the rejection rate visible |
| D5-10 | Provider failures on generation = D5-7: `APIConnectionError`/timeout, 429, ≥ 500 (after the SDK retry) → template with `fallback_reason=api_error`; any other 4xx propagates → job fails with retries → incident. Per call: timeout 30 s, SDK `max_retries` 1 (classify keeps 30 s / 2); job timeout 90 s for `ticket.answer`/`ticket.notify` (30 s for the rest) | Same reasoning as D5-7. The two numbers belong together: one attempt is at most 60 s (2 × 30 s), the guardrail retry is a second attempt, and the 90 s job timeout has to outlast the attempt that actually happens — the SDK only retries on transport/429/5xx, so both attempts hitting the retry is the theoretical worst case, which then fails the job cleanly instead of running twice |
| D5-11 | Knowledge base `prompts/kb_tourism.md`: 11 sections with stable ids (`## KB-01` …), **no amounts, limits or deadlines** — booking-specific figures are pointed to ("as stated in your booking confirmation", "on your e-ticket"). Appended to the answer system prompt (cached block). Questions outside the KB or depending on the booking → honest handover to an agent with `usedKbIds = ["KB-11"]`, no invention. Every answer cites `usedKbIds`; `answerKbIds` reaches the process scope (v8 output mapping) | A KB without figures cannot be misquoted, which keeps the grounding check binary. Citations make an answer auditable and give the KB a usage signal per section |
| D5-7 | **Provider failures only** degrade to the keyword fallback (`needsReview=true`, `fallback_reason=api_error`, ERROR log, job completes): network errors and timeouts (`APIConnectionError` incl. `APITimeoutError`), `RateLimitError` (429), `InternalServerError` / status ≥ 500 — after the SDK's 2 retries. **Any other 4xx** (`BadRequestError`, `AuthenticationError`, `PermissionDeniedError`, `NotFoundError`) is our code/config bug: the exception propagates, the job fails with retries → incident in Operate, as in D5-3 | An LLM *outage* degrades to keyword routing with mandatory human review instead of stalling the queue — but a malformed request would fail identically forever, and masking it as a fallback would hide a defect; that class must surface as an incident. Trade-off, accepted deliberately: provider outages do **not** show in Operate — only in the audit (`fallback_used`, `fallback_reason`) and the logs |
| D5-12 | **Amendment to D5-3 (Phase 6.1):** every PostgreSQL connection is opened with libpq `connect_timeout=5` — at startup (`connect_with_retry`) and on the per-job reconnect after a reset. No other classifier change; the LLM-before-audit order stays (backlog, Phase 7) | A database that accepts TCP but never answers (paused container, black-holed route) would otherwise hang the handler until the 30 s job timeout, and the engine would re-activate the job into the same hang — with the timeout the audit write fails fast and the job fails with `retries - 1` as D5-3 intends |

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
  llm_sentiment, final_sentiment, escalated, reviewed_at)` — one row per completed
  `review-classification`, written by the `review.record` job (§5, since 5.3).

## 5. Review path (implemented in 5.3)

`record-review` (job type `review.record`, process v7) runs right after the user task,
on the escalate path as well. The handler in `worker.py` reads `ticketId`, `runId`,
`intent`, `sentiment`, `escalate`, `reviewedBy` from the job, looks up `llm_intent` /
`llm_sentiment` in the latest `llm_audit` row of the same `(ticket_id, run_id)` and
inserts the `classification_review` row: `final_*` from the form, `reviewed_by` from
`reviewedBy` (`"unknown"` if missing or empty — the FEEL default on the task already
does this, the worker repeats it defensively), `escalated` from `escalate`. A database
failure fails the job (D5-3), so an unrecorded review becomes an incident, not a silent
gap. The e2e `--check` asserts T-1004's row (`other` → `question`).

Analytics question the table answers: how often and in which direction humans overrule
the model per intent — the input for the next prompt/threshold calibration.

## 6. Generation path (implemented in 5.4)

```mermaid
flowchart TD
    J["ticket.answer / ticket.notify job"] --> L["reply language (D5-8)"]
    L --> M["user message = language + the input fields as JSON<br/>answer: ticketId, subject, body, bookingRef<br/>notify: ticketId, resolution, subject, bookingRef,<br/>refundAmountCustomer, customerCurrency, answerText, slaDeadline"]
    M --> P["ClaudeProvider (LLM_MODEL_GENERATE, max_tokens 1024,<br/>timeout 30s, max_retries 1, structured output)<br/>answer system prompt = answer_v1 + KB (cached)"]
    P --> V{"schema + local checks (D5-9)<br/>language · numbers grounded · KB ids · ≤ 1200"}
    V -- ok --> OK["source = llm"]
    V -- "violation → retry with the message" --> P2[second call]
    P2 --> V2{ok?}
    V2 -- yes --> OK
    V2 -- no --> F["template from rules.py<br/>source = fallback"]
    P -. "network/timeout/429/5xx → api_error (D5-10)" .-> F
    P -. "other 4xx → exception → incident" .-> I[incident]
    OK --> A; F --> A
    A["audit row (D5-3): job_type answer|notify, model from response.model,<br/>output {text, language, usedKbIds, source, violations, fallback_reason}"]
    A --> OUT["answer: answerText, answerSource, answerKbIds<br/>notify: customerMessage, messageLanguage, notifySource<br/>+ notificationTemplate, notifiedAt (deterministic); delivery = log line"]
```

The generator (`generator.py`) is Camunda- and database-free like the classifier;
`tests/generation/report.py` drives it over `questions.json` (10 questions, RU/EN, 3
outside the KB) and writes `report-answer_v1.md`: gates are zero grounding violations on
any attempt and no in-KB question ending in the template.

**`answer_v1` record (2026-09-25, claude-sonnet-5):** 0 grounding violations, 0 other
rejections, 7/7 in-KB questions cite the expected section, 3/3 outside-KB questions hand
over (KB-11 cited, Q-09 together with the KB-07 section it partially answered from), 0
fallbacks, cost $0.033 per run with the cached prompt (write 2433 / read 21897 tokens).
Live acceptance run `20260925T121224Z`: every e2e ticket `message ok (en/llm)`, zero
fallbacks, `llm_audit` rows for answer and notify with the exact model id.

**Known limit of the grounding check:** it is numeric. The Q-04 answer listed the company
details an invoice needs (name, tax id, legal address) although KB-06 did not name them —
plausible, non-numeric policy that no check catches. The KB now states the list (KB edit,
no prompt version bump); the general defence stays the prompt's "use only the knowledge
base" rule plus the report review, not a guardrail. Parked as a 5.5 review item. The e2e `--check` asserts per
ticket a non-empty `customerMessage` in the ticket language, `answerText`/`answerKbIds` on
the answered branch and the refund amount inside the refund message.

Variables (process scope; `answer*` via the v8 output mappings on `answer-question`,
`notify-customer` has no mappings so its completion variables land in the process scope
directly):

| Variable | Set by | Value |
|---|---|---|
| `answerText` | `ticket.answer` | the grounded answer or the handover template |
| `answerSource` | `ticket.answer` | `llm` \| `fallback` |
| `answerKbIds` | `ticket.answer` | cited KB ids; `["KB-11"]` = handed over to an agent |
| `customerMessage` | `ticket.notify` | the final message (greeting, body, closing) |
| `messageLanguage` | `ticket.notify` | `ru` \| `en` (D5-8) |
| `notifySource` | `ticket.notify` | `llm` \| `fallback` |

## 4. Configuration

| Variable | Where | Meaning |
|---|---|---|
| `DATABASE_URL` | `infra/.env` (no default; password must match `POSTGRES_PASSWORD`) | audit connection |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | `infra/.env` | database bootstrap |
| `ANTHROPIC_API_KEY` | `infra/.env` | provider key (used from 5.2) |
| `LLM_MODEL_CLASSIFY` / `LLM_MODEL_GENERATE` | `infra/.env`, defaults in compose | model aliases per D5-1 |
| `CLASSIFY_CONFIDENCE_THRESHOLD` | `infra/.env`, default 0.8 | D5-2; calibrated in 5.2 |
| `CLASSIFY_PROMPT_VERSION` | `infra/.env`, default `classify_v2` | selects `prompts/<version>.md`; stamped into output and audit |
| `ANSWER_PROMPT_VERSION` / `NOTIFY_PROMPT_VERSION` | `infra/.env`, defaults `answer_v1` / `notify_v1` | generation prompts (5.4); the KB `prompts/kb_tourism.md` has a fixed name and is appended to the answer prompt |
| generation timeouts (code, `generator.py` / `worker.py`) | provider timeout 30 s, SDK `max_retries` 1; job timeout 90 s for `ticket.answer`/`ticket.notify` | D5-10 — the pair must be changed together |
| `PROMPTS_DIR` | optional | prompt location override; default `/app/prompts` (compose mount) or the repo's `prompts/` in the venv run |

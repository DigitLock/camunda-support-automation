# Backlog

Ideas parked here to keep the current phase focused. Each entry names the phase it could fit into.

## Parked ideas
   - **FX — swap the fx-gateway `RateProvider` to the shared currency-rate-service**
     (`FX_BASE_URL` / gRPC client) once that service is deployable; the `/convert` contract
     stays unchanged, so the REST connector does not notice the switch.
   - **currency-rate-service repository debt (tracked there, not here):** Dockerfile +
     grpc-gateway (REST) + PostgreSQL/migrations/provider seeding — option (a) of the
     2026-09-24 assessment, ~5–6 h.
   - **Own Kafka consumer (Go)** — only if the Camunda Kafka connector's semantics prove
     insufficient (DLQ, batching, transactional produce); see ADR-007.
   - **Phase 6 — Dedicated worker user instead of admin.** The Phase 2 stub worker (and until
     then any worker) authenticates as `admin`; create a `worker` user with only the needed
     authorizations and switch `CAMUNDA_USER` over.
   - **Phase 6 — Error boundary on the booking tasks (scenario B).** Input from the 5.5
     finding (`docs/ops/install.md`, "instance loops on a service task with no incident"):
     since the worker fix, an unknown `bookingRef` throws `BOOKING_NOT_FOUND` correctly and
     the instance gets an **incident on `cancel-refund`** because the model has no boundary
     event for it. Scenario B: catch the error, route to `handle-by-agent`, then resolve the
     live incident by instance migration. Reproduce: `send-tickets.sh --probe-unknown-booking`.

     ![Operate: silent loop before the worker fix](assets/phase-5/silent-loop-before-fix.png)

     *Before the fix — instance green, token on cancel-refund, no incident; the worker logged the 404 every 60 s.*

     ![Operate: incident BOOKING_NOT_FOUND after the fix](assets/phase-5/incident-booking-not-found.png)

     *After the fix — the same ticket raises `UNHANDLED_ERROR_EVENT` on cancel-refund: the error is thrown, nothing catches it yet.*
   - **Phase 6 — Password rotation on an existing cluster.** `camunda.security.initialization`
     only creates users on a fresh secondary storage; document and rehearse changing the
     `admin` and `connectors` passwords on a running stand (API/UI change + `.env` update +
     rolling restart) as part of the operations runbooks.
   - **Re-pin `camunda-orchestration-sdk`** when a stable 8.9.x is published (currently
     pinned to `8.9.0.dev39`; the stable 9.0.x line targets server 8.10).
   - **Measure install-from-scratch time** on the next clean-OS-plus-Docker run; recorded as
     ≤ 10 min without errors (design D2-6), not yet timed.
   - **Phase 7 — `answer_v2` candidate:** do not mix scripts inside one reply (a Russian
     answer wrote "voucher" where «ваучер» was expected), one language per reply; bump the
     prompt version and re-run `tests/generation/report.sh`. Not implemented in Phase 5.
   - **After Phase 8 — Camunda Non-Commercial License application.** The stand currently runs
     without a key ("Non-Production License" banner). Apply for the non-commercial license and
     add the key through the environment once the project is published.

## Phase 5 milestones

| Step | Scope | Status |
|---|---|---|
| 5.0 | Design decisions D5-1…D5-6 (`docs/design/llm-classifier-v1.md`), ADR-004 amendment | done |
| 5.1 | PostgreSQL + audit schema, worker rename to `workers/llm-classifier`, audit-writing skeleton, provider interface, smoke | done (acceptance run pending) |
| 5.2 | Claude classify call, JSON-schema guardrails, retry + fallback, threshold calibration (`tests/classification/report.sh`) | done — e2e 6/7 on v6, T-1004 blocked by D4-6 until v7 (5.3) |
| 5.3 | Process v7: review loop re-routes (D5-4), explicit output mappings `intent`/`sentiment`/`escalate`/`reviewedBy` on `review-classification` (D4-6, unblocks T-1004), `record-review` → `classification_review` writes, `slaDeadline` normalised (D3-11) | done (run 20260925T063333Z) |
| 5.4 | Process v8 (output mappings on `answer-question`), LLM `ticket.answer` (grounded in `prompts/kb_tourism.md`, D5-11) and `ticket.notify` (D5-5) on `LLM_MODEL_GENERATE`, generation guardrails D5-8…D5-10, `tests/generation/report.sh`, e2e generation checks | done (run 20260925T121224Z) |
| 5.5 | Acceptance, docs, screenshots. Also: `review-classification` form — the Text view renders live form values, so after the agent changes a select the block labelled "LLM classification" shows the corrected value, not the LLM snapshot; form fixed by the owner (Text view shows source/confidence/language/rationale only, redeployed on v8). T-1008 (Russian cancel_refund, TRY) in `tests/e2e/tickets.json`; `--manual-user-tasks` lists every open task of the run; `make check-public`; `docs/design/llm-guardrails.md`; booking-worker fix (throw-error path, lifecycle fallback) | done (run 20260925T142455Z) |

### Phase 5 acceptance (against the plan)

| Criterion (plan) | Result | Evidence |
|---|---|---|
| ≥ 85 % classification accuracy on the labelled test set | **100 %** intent (35/35 non-ambiguous), 97.5 % sentiment, 100 % language, 0 silent errors, 5/5 ambiguous tickets to review, 39/40 stable across 3 runs | `tests/classification/report-latest.md` (`classify_v2`, threshold 0.8, Haiku) |
| Every low-confidence ticket goes to Tasklist | Threshold 0.8 sits in the 0.75–0.85 gap; live: T-1004 (`other` → corrected to `question`, re-routed through the DMN) and T-1006 (borderline) reach `review-classification`; the review is recorded in `classification_review` | e2e runs `20260925T063333Z`, `20260925T121224Z`; screenshots `docs/assets/phase-5/` |
| LLM outputs validated and auditable | Two-layer schema, fallback and incident semantics; every LLM job leaves an `llm_audit` row with the exact model id; generation: 0 grounding violations, 0 fallbacks, cost $0.033/run | `docs/design/llm-guardrails.md`, `tests/generation/report-answer_v1.md` |
| Customer text grounded, both languages | 8/8 e2e tickets with `message ok`, T-1008 `message ok (ru/llm)` with the refund amount in the Russian text | `tests/e2e/send-tickets.sh --check`, run `20260925T142455Z` |
| Human review reachable for every borderline ticket | `--manual-user-tasks` listed T-1004, T-1005 and T-1006 (borderline) | run `20260925T142455Z` |
| Failures surface, never loop silently | `--probe-unknown-booking`: incident on `cancel-refund`, `UNHANDLED_ERROR_EVENT` "Expected to throw an error event with the code 'BOOKING_NOT_FOUND' … but it was not caught" — after the booking-worker fix (before: silent 60 s loop) | `docs/ops/install.md`, `docs/assets/phase-5/silent-loop-before-fix.png`, `incident-booking-not-found.png` |
| Public repo clean | `make check-public` exits 0 (pattern from the owner's shell environment) | Makefile |
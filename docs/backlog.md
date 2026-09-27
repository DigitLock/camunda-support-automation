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
   - **Phase 6 items moved into the plan** (2026-09-25): dedicated worker user and password
     rotation → 6.6, error boundary on the booking tasks / scenario B → 6.2; the Phase 5.5
     evidence stays here:

     ![Operate: silent loop before the worker fix](assets/phase-5/silent-loop-before-fix.png)

     *Before the fix — instance green, token on cancel-refund, no incident; the worker logged the 404 every 60 s.*

     ![Operate: incident BOOKING_NOT_FOUND after the fix](assets/phase-5/incident-booking-not-found.png)

     *After the fix — the same ticket raises `UNHANDLED_ERROR_EVENT` on cancel-refund: the error is thrown, nothing catches it yet.*
   - **Phase 7 — metrics endpoints on the Go services and the Python worker** (`/metrics`,
     scraped by the monitoring profile). Phase 6 scrapes the engine only (D6-7).
   - **Phase 7 — import the official Zeebe Grafana dashboard** (`monitor/grafana/zeebe.json`,
     850 KB) by hand when a detail view (RocksDB, stream processor latency) is wanted; not
     vendored (D6-6).
   - **Re-pin `camunda-orchestration-sdk`** when a stable 8.9.x is published (currently
     pinned to `8.9.0.dev39`; the stable 9.0.x line targets server 8.10).
   - **Measure install-from-scratch time** on the next clean-OS-plus-Docker run; recorded as
     ≤ 10 min without errors (design D2-6), not yet timed.
   - **Phase 7 — `handle-by-agent` assignee is lost on modification.** Re-arming the SLA
     timer (or any Modify that re-creates the user task) yields a new `userTaskKey` with no
     assignee (`docs/runbooks/sla-escalation.md` §5). Re-assign automatically (task listener
     or worker) or document it as an operator step.
   - **Phase 7 — worker-llm-classifier: SDK job polling is logged at DEBUG** (5 job types ×
     every ~11 s), which buries the handler lines. Raise the worker's log level to INFO or
     silence `camunda_orchestration_sdk.runtime.logging`.
   - **Phase 7 — classifier: add `retryBackOff`.** The SDK fails a job with backoff 0, so
     the three retries run within 3 s and a 5–10 s PostgreSQL restart already produces an
     incident (A3b in `docs/runbooks/incident-handling.md`). A `JobFailure(retry_back_off=…)`
     raised from the audit path, or a worker-level default, would let short restarts heal.
   - **Phase 7 — classifier calls the LLM before the audit write**, so each retry of a
     failed audit write (A3b in `operations-v1.md`) costs an extra LLM call — reorder the
     steps or cache the LLM result per `jobKey`. Observed in Phase 6.1; no change now.
   - **Phase 7 — `answer_v2` candidate:** do not mix scripts inside one reply (a Russian
     answer wrote "voucher" where «ваучер» was expected), one language per reply; bump the
     prompt version and re-run `tests/generation/report.sh`. Not implemented in Phase 5.
   - **Phase 7 — observation report to camunda/camunda on the restore-path field loss.** One
     occurrence (2026-09-27, 8.9.21, backup 1790507500): after a restore, eight instances
     completed shortly before the backup came back with `startDate = null`, snapshot intact.
     The source-based reading — the archiver reindex (no `op_type`, `conflicts: proceed`)
     overwriting a restored full list-view document with the partial one the re-export of the
     acknowledged-position tail creates — is a hypothesis, **not reproduced** in two clean
     round-trips with the exporter-sync wait (which never had to wait). No existing issue
     found. Write it as an observation with the evidence (`verify-state.sh` lines, the
     renamed-index peek, the two clean runs), not as a bug with reproduction steps
     (`docs/runbooks/backup-restore.md` §6).
   - **Phase 7 — `thin_pool` autoextend on the Proxmox node (homelab).** Enable
     `thin_pool_autoextend_threshold` / `thin_pool_autoextend_percent` in `lvm.conf` so a
     filling LVM thin pool grows instead of taking the stand VM read-only. Node-side change,
     not in this repository; noted here so it is not forgotten before the next backup rehearsal.
   - **Phase 7 — decide whether `camunda_dated_<id>` stays or goes.** The extra snapshot of the
     day-suffixed indices (`backup.sh` step 3b, the dated branch in `restore.sh`, §1 of the
     runbook) is not a mitigation for the §6 loss. Evidence so far: taken in round-trips #2
     and #3, **skipped by `restore.sh` in both** — every day-suffixed index came back with
     the web-apps parts. Either remove it (smaller scripts, one snapshot type less to
     explain) or keep it and justify it in §1 as protection against a different failure.
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
## Phase 6 milestones

Design and decisions D6-1…D6-7: `docs/design/operations-v1.md`. Decisions taken by the
owner on 2026-09-25: monitoring profile on the stand VM, backups to local disk, `slaOverride`.

| Step | Scope | Status |
|---|---|---|
| 6.0 | Design decisions D6-1…D6-7, plan, ADR-008 | done 2026-09-25 |
| 6.1 | Incident scenario A, no BPMN change: booking worker fails 5xx/timeout/transport with `retryBackOff` (`RETRY_BACKOFF`, default `PT10S`) and a self-explanatory errorMessage + WARN log line; booking-api runtime outage toggle (`/admin/fault`, `/app -fault`, `make fault-on/off/status`); classifier `connect_timeout=5` (D5-12); e2e `--probe-booking-5xx`, `--probe-outage`, `--probe-classify`, `--incidents`; `tests/smoke/phase-6-infra.sh`; A1/A2/A3a/A3b run on the stand, runbook `docs/runbooks/incident-handling.md`, screenshots `docs/assets/phase-6/`; install.md entry (`make deploy` deletes files next to `.env`) | done 2026-09-26 (committed 62705bd) |
| 6.2 | Scenario B: process v9 = v8 + interrupting `BOOKING_NOT_FOUND` boundary events `err-booking-not-found-cancel` / `err-booking-not-found-change` → `handle-by-agent`, output mappings `errorCode`/`errorMessage` from the throw-error payload (owner, D6-8; the worker sends the payload); two live v8 incidents resolved by instance migration v8 → v9 — one through the Operate UI, one through `tests/ops/migrate-instance.sh` — then Retry, caught by the new boundary event; `--probe-unknown-booking` reports incident (v8) or open task (v9); timeout stays scenario A (`--probe-timeout`, D6-10, cancelled); regression 8/8 on v9; runbooks `docs/runbooks/migration.md`, `docs/runbooks/timeout.md`; `process-v1.md` v8→v9; screenshots `b-*`, `c-*` | done 2026-09-26 (committed 150cff5) |
| 6.3 | SLA escalation, decision "C": process v10 = v9 + `slaOverride` in the start event and the `slaDeadline` mapping (D6-3, no fallback), non-interrupting `sla-timer` on `handle-by-agent` → `escalate-sla` (`sla.escalate`) → `end-sla-escalated` (owner); worker `sla.escalate` in the classifier (priority 90 + `supervisors` on the live task, `sla_escalation` audit table, D6-5); T-1009 (`probeOnly`, `PT2M`, `BK-UNKNOWN`, TRY) and `--probe-sla`; migration v9 → v10 of a waiting user task as the second migration case (D6-9, `migrate-instance.sh` timer hint); runbook `docs/runbooks/sla-escalation.md` (incl. re-arming an already subscribed timer by modification); `process-v1.md` v9→v10; `handle-by-agent` form shows `errorMessage` (redeployed with v10) | done 2026-09-26 (committed c5f4f8b) |
| 6.4 | Backup/restore to local disk under `/srv/camunda-backups` (ES `fs` repository, Zeebe `FILESYSTEM` store, web-apps backup, `pg_dump`): `tests/ops/backup.sh`, `restore.sh` (`--pause-after-seed`), `pg-backup.sh`, `pg-restore.sh`, `verify-state.sh`, smoke `tests/smoke/phase-6-backup.sh`, runbook `docs/runbooks/backup-restore.md`; patch upgrade: no newer 8.9.x exists, so the patch path is rehearsed on `infra/upgrade-lab/` (8.9.19 → 8.9.21, `tests/ops/upgrade-lab.sh`, `docs/ops/upgrade.md`); minor path 8.8 → 8.9 not rehearsed (`docs/lessons-learned.md`) | done 2026-09-27 — three backup/restore round-trips on the stand (1790507500 with the repository gap and the `startDate` finding; 1790534421 and 1790535095 clean with mitigation A, `wait_exporter_sync` before the soft-pause); the finding stays at "not reproduced in 2 of 2, mechanism a hypothesis" (runbook §6); lab 8.9.19 → 8.9.21 with three waiting instances resumable, three cosmetic script fixes (`upgrade.md` §3) |
| 6.5 | Monitoring: deploy the `monitoring` profile (Prometheus `v3.15.0`, Grafana `13.2.2`, alert `incidents > 0`, dashboard `camunda-stand`, `tests/smoke/phase-6-monitoring.sh`) — **the repository side exists since 6.0** (compose profile, `infra/config/prometheus/`, `infra/config/grafana/`, the Prometheus endpoint in `application.yaml`, `.env.example` variables, install.md section), nothing is deployed; password rotation rehearsed; `worker` user with scoped authorizations, workers switched from `admin` | repo side of monitoring done 2026-09-25; rest planned. **Check first:** on the 6.1 deploy `orchestration` did not restart although `application.yaml` changed (bind-mounted file — Compose sees no service change?); verify with `docker compose ps` timestamps and `docker compose up -d --force-recreate orchestration` before the monitoring deploy, and only then write the install.md entry |
| 6.6 | Acceptance against §8 of the design, screenshots `docs/assets/phase-6/`, traceability, README status | planned |

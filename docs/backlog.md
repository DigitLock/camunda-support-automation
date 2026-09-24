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
   - **Phase 6 — Password rotation on an existing cluster.** `camunda.security.initialization`
     only creates users on a fresh secondary storage; document and rehearse changing the
     `admin` and `connectors` passwords on a running stand (API/UI change + `.env` update +
     rolling restart) as part of the operations runbooks.
   - **Re-pin `camunda-orchestration-sdk`** when a stable 8.9.x is published (currently
     pinned to `8.9.0.dev39`; the stable 9.0.x line targets server 8.10).
   - **Measure install-from-scratch time** on the next clean-OS-plus-Docker run; recorded as
     ≤ 10 min without errors (design D2-6), not yet timed.
   - **Phase 5 — Normalise `slaDeadline` (D3-11) — now mandatory.** The zoned date-time
     format (`...Z[GMT]`) no longer stays internal: since process v6 it leaves the stand in
     `support.ticket.resolved` events, so external consumers see a non-ISO value.
   - **After Phase 8 — Camunda Non-Commercial License application.**

## Phase 5 milestones

| Step | Scope | Status |
|---|---|---|
| 5.0 | Design decisions D5-1…D5-6 (`docs/design/llm-classifier-v1.md`), ADR-004 amendment | done |
| 5.1 | PostgreSQL + audit schema, worker rename to `workers/llm-classifier`, audit-writing skeleton, provider interface, smoke | done (acceptance run pending) |
| 5.2 | Claude classify call, JSON-schema guardrails, retry + fallback, threshold calibration (`tests/classification/report.sh`) | planned |
| 5.3 | Process v7: review loop re-routes (D5-4), `classification_review` writes — Modeler by the owner | planned |
| 5.4 | LLM `ticket.answer` (grounded in `prompts/kb_tourism.md`) and `ticket.notify` (D5-5) | planned |
| 5.5 | Acceptance, docs, screenshots | planned | The stand currently runs
     without a key ("Non-Production License" banner). Apply for the non-commercial license and
     add the key through the environment once the project is published.
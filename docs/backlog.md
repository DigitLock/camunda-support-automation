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
   - **send-tickets.sh — pre-flight check for active instances of `support-request-v1`.**
     A live instance with the same correlationKey silently drops the new message, so a stale
     run makes the next one fail confusingly.
   - **Measure install-from-scratch time** on the next clean-OS-plus-Docker run; recorded as
     ≤ 10 min without errors (design D2-6), not yet timed.
   - **After Phase 8 — Camunda Non-Commercial License application.** The stand currently runs
     without a key ("Non-Production License" banner). Apply for the non-commercial license and
     add the key through the environment once the project is published.
# Backlog

Ideas parked here to keep the current phase focused. Each entry names the phase it could fit into.

## Parked ideas
   - **Phase 4 — Currency Rate Service as the external FX dependency.** The service is gRPC-only
     and not deployed yet. Work in its own repository: (1) `google.api.http` annotations and
     grpc-gateway on the existing HTTP port, (2) multi-stage Dockerfile, (3) Compose deployment on
     the shared Docker host with its own PostgreSQL (no published port) and migrations, (4) curl
     verification. Consumed through `FX_BASE_URL`. Time-box: half a day; fallback — the REST
     connector calls a public FX API directly.
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
   - **Phase 4 — Raise the SDK log level in the stub worker to INFO.** The SDK's DEBUG
     polling output every ~10 s floods the log and drowns the `job=...` lines.
   - **Phase 4 — Graceful client shutdown in workers.** The stub worker does not close the
     SDK client on Ctrl-C; the Go workers should get clean shutdown from the start.
   - **After Phase 8 — Camunda Non-Commercial License application.** The stand currently runs
     without a key ("Non-Production License" banner). Apply for the non-commercial license and
     add the key through the environment once the project is published.
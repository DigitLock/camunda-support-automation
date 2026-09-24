# Stub worker (Phase 2+)

One Python process that subscribes to three job types of `support-request-v1`
(`ticket.classify`, `ticket.answer`, `ticket.notify`) and completes them with the
deterministic values from `docs/design/process-v1.md` §7. Routing moved to DMN in Phase 3
(`docs/design/routing-v1.md`); the `booking.*` types moved to the Go worker in Phase 4
(`workers/booking/`). `ticket.classify` and `ticket.notify` stay here for the Phase 5
LLM classifier.

Since Phase 4 the worker runs as a container in the `workers` compose profile (ADR-006):
built by `make deploy`, healthcheck on `:8081/healthz`, clean shutdown on SIGTERM. The venv
run below remains the dev fallback.

## Version pin

`camunda-orchestration-sdk==8.9.0.dev39` — no stable 8.9.x of the SDK is on PyPI yet
(checked 2026-09-22; only `8.9.0.devN` pre-releases exist for server 8.9, the stable line
starts at 9.0 for server 8.10). Pinned to the newest 8.9 pre-release; revisit when a stable
8.9 SDK is published.

## Install (dev fallback — venv)

```bash
cd workers/stub
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

## Configure and run

```bash
cp .env.example .env    # then set CAMUNDA_PASSWORD (admin password from infra/.env on the stand)
set -a; source .env; set +a    # required: the worker does not read .env itself
.venv/bin/python worker.py
```

Run the worker as the stand's deploy user, never as root — root-owned files under
`workers/stub/` break `make sync` later (see the rsync error 23 entry in
`docs/ops/install.md`).

The worker long-polls the three job types and logs one line per completed job:
`job=<type> ticketId=<id> -> <returned variables>`. Stop with Ctrl-C (or SIGTERM in
compose). The SDK's own logger stays at INFO (`LOG_LEVEL` overrides) so empty-poll DEBUG
lines do not drown the job lines.

Uses the `admin` user for now; a dedicated worker user is parked in `docs/backlog.md`
for Phase 6.

## Handlers

Pure functions in `handlers.py` (dict in → dict out, no SDK types — portable to Go one at a
time); keyword tables and thresholds live in `rules.py`.

| Job type | Returns |
|---|---|
| `ticket.classify` | `intent`, `confidence` from the ordered subject keyword rules; `sentiment` (`negative` if body contains angry/terrible, else `neutral`); `needsReview` = confidence < 0.7 |
| `ticket.answer` | `{}` (logs only) |
| `ticket.notify` | `notificationTemplate` = `notify-<resolution>`, `notifiedAt` (ISO 8601 UTC) |

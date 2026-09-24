# Stub worker (Phase 2+)

One Python process that subscribes to five job types of `support-request-v1` and completes
them with the deterministic values from `docs/design/process-v1.md` §7. The routing job type
moved to DMN in Phase 3 (`docs/design/routing-v1.md`) — the worker no longer serves it.
Temporary by design: Phase 4 moves the `booking.*` and `ticket.answer` types to Go workers,
`ticket.classify` and `ticket.notify` stay in Python for the Phase 5 LLM classifier.

## Version pin

`camunda-orchestration-sdk==8.9.0.dev39` — no stable 8.9.x of the SDK is on PyPI yet
(checked 2026-09-22; only `8.9.0.devN` pre-releases exist for server 8.9, the stable line
starts at 9.0 for server 8.10). Pinned to the newest 8.9 pre-release; revisit when a stable
8.9 SDK is published.

## Install

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

The worker long-polls the five job types and logs one line per completed job:
`job=<type> ticketId=<id> -> <returned variables>`. Stop with Ctrl-C.

Uses the `admin` user for now; a dedicated worker user is parked in `docs/backlog.md`
for Phase 6.

## Handlers

Pure functions in `handlers.py` (dict in → dict out, no SDK types — portable to Go one at a
time); keyword tables and thresholds live in `rules.py`.

| Job type | Returns |
|---|---|
| `ticket.classify` | `intent`, `confidence` from the ordered subject keyword rules; `sentiment` (`negative` if body contains angry/terrible, else `neutral`); `needsReview` = confidence < 0.7 |
| `booking.change` | `{}` (logs only) |
| `booking.cancel` | `{}` (logs only) |
| `ticket.answer` | `{}` (logs only) |
| `ticket.notify` | `notificationTemplate` = `notify-<resolution>`, `notifiedAt` (ISO 8601 UTC) |

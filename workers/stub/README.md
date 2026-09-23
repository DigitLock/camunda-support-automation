# Stub worker (Phase 2)

One Python process that subscribes to all six job types of `support-request-v1` and completes
them with the deterministic values from `docs/design/process-v1.md` §7. Temporary by design:
Phase 4 moves the `booking.*` and `ticket.answer` types to Go workers, `ticket.classify` and
`ticket.notify` stay in Python for the Phase 5 LLM classifier.

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
set -a; source .env; set +a
.venv/bin/python worker.py
```

The worker long-polls the six job types and logs one line per completed job:
`job=<type> ticketId=<id> -> <returned variables>`. Stop with Ctrl-C.

Uses the `admin` user for now; a dedicated worker user is parked in `docs/backlog.md`
for Phase 6.

## Handlers

Pure functions in `handlers.py` (dict in → dict out, no SDK types — portable to Go one at a
time); keyword tables and thresholds live in `rules.py`.

| Job type | Returns |
|---|---|
| `ticket.classify` | `intent`, `confidence` from the ordered subject keyword rules; `sentiment` (`negative` if body contains angry/terrible, else `neutral`); `needsReview` = confidence < 0.7 |
| `ticket.route` | `team` by intent (bookings/refunds/support/escalation), `priority` (`high` for premium tier else `normal`), `slaHours` (4/24) |
| `booking.change` | `{}` (logs only) |
| `booking.cancel` | `{}` (logs only) |
| `ticket.answer` | `{}` (logs only) |
| `ticket.notify` | `notificationTemplate` = `notify-<resolution>`, `notifiedAt` (ISO 8601 UTC) |

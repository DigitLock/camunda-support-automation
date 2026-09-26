# Booking worker

Go worker (stdlib only) for the `booking.change` and `booking.cancel` job types: activates
jobs over the Orchestration Cluster REST API v2 (long polling, Basic auth) and calls the
mock Booking API. One binary serves both types (D4-2). Runs as a container in the `workers`
compose profile (ADR-006).

## Environment

| Variable | Required | Meaning |
|---|---|---|
| `CAMUNDA_BASE_URL` | yes | e.g. `http://orchestration:8080` (compose) |
| `CAMUNDA_USER` / `CAMUNDA_PASSWORD` | yes | Basic auth (admin until the Phase 6 worker user) |
| `BOOKING_API_URL` | yes | e.g. `http://booking-api:8080` |
| `RETRY_BACKOFF` | no | ISO 8601 duration (`PnDTnHnMnS` subset, e.g. `PT10S`, `PT1M30S`), default `PT10S`: the job is not re-activated before *now + backoff* after a failure (`retryBackOff` on `POST /v2/jobs/{key}/failure`). Invalid value → the worker exits at startup. Compose sets it from `BOOKING_RETRY_BACKOFF` in `infra/.env` (Phase 6.1) |
| `LOG_LEVEL` | no | `DEBUG` / `INFO` (default) / `WARN` / `ERROR` |

## Error contract (D4-1, `docs/design/integrations-v1.md`)

| Booking API outcome | Job action |
|---|---|
| 2xx | complete with `{bookingStatus}`; for `booking.cancel` additionally `{refundAmount, refundCurrency}` — the booking's value and currency from the API response |
| 404, or `bookingRef` missing/null | BPMN error `BOOKING_NOT_FOUND` |
| 5xx, client timeout (10 s) or transport error | fail with `retries - 1`, `retryBackOff` = `RETRY_BACKOFF`, errorMessage `booking-api HTTP 500 on POST /bookings/BK-FAIL-500/cancel (retries left: 2)` (cause is `HTTP <n>`, `timeout after 10s` or `transport error: …`); the same text is the incident message in Operate once retries are exhausted (`JOB_NO_RETRIES`, after 3 × `RETRY_BACKOFF` ≈ 20 s with the defaults) |

Activation: `maxJobsToActivate` 5, long-poll `requestTimeout` 10 s, job `timeout` 60 s
(headroom over the mock API's `BK-FAIL-TIMEOUT` 30 s delay).

SIGTERM stops activation, waits up to 25 s for in-flight jobs (compose `stop_grace_period`
is 30 s) and exits 0. `/healthz` on :8081 returns 200 while the last successful poll is
younger than 60 s; the compose healthcheck runs `/app -check` (scratch image, no shell).
One log line per event (`activated` / `completed` / `failed` / `error`) with jobKey, type
and bookingRef. A `failed` line is level WARN and adds `processInstanceKey`, `elementId`,
`httpStatus` (0 for timeout/transport), `retriesLeft`, `retryBackOff` and `reason` — enough
to find the instance in Operate without opening it (Phase 6.1 scenario A).

## Local dev run (against the stand)

```bash
cd workers/booking
CAMUNDA_BASE_URL=http://<stand>:8080 CAMUNDA_USER=admin CAMUNDA_PASSWORD=... \
BOOKING_API_URL=http://<stand-internal-only>:8080 go run .
```

Note: `booking-api` is not published on the VM's host — for a fully local dev loop run the
mock API locally too (`go run ./services/booking-api`) and point `BOOKING_API_URL` at it.

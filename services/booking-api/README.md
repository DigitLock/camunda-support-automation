# Mock Booking API

In-memory booking service for the stand (Go stdlib, scratch image). Backs the `booking.change`
and `booking.cancel` job types from Phase 4 on. No persistence: state resets on restart.

## Endpoints

| Method & path | Behaviour |
|---|---|
| `GET /bookings/{id}` | booking JSON or 404 |
| `POST /bookings/{id}/change` | sets `status: "changed"`; optional body `{"travelDate": "YYYY-MM-DD"}` updates the date |
| `POST /bookings/{id}/cancel` | sets `status: "cancelled"` |
| `GET /healthz` | liveness; also probed by the container healthcheck via `/app -check` (scratch has no shell) |
| `GET /admin/fault` | outage toggle state: `{"active": false, "status": 0}` or `{"active": true, "status": 503, "since": "<UTC>"}` |
| `PUT /admin/fault?status=503` | switch the outage **on**: every `/bookings/*` request answers with `status` (500–599, default 503) until switched off |
| `DELETE /admin/fault` | switch the outage **off** |

Booking fields: `id`, `customerId`, `value`, `currency`, `bookedAt`, `travelDate`, `status`.

Seed data: `BK-77`, `BK-81`, `BK-90` (EUR, aligned with `tests/e2e/tickets.json`; `BK-90`
is also the ref of the Russian refund ticket T-1008) and `BK-1001` (USD 1050, used by the
FX conversion path). Any other id is a 404 → `BOOKING_NOT_FOUND` in the worker.

## Deterministic failures (by booking id)

| ID | Behaviour |
|---|---|
| `BK-FAIL-500` | immediate 500 |
| `BK-FAIL-TIMEOUT` | responds only after 30 s (the client is expected to time out first) |
| any unknown id | 404 |

## Runtime outage toggle (Phase 6.1, scenario A2)

The fault is in-memory and off after every start. While it is on, `/bookings/*` returns the
configured status with `{"error": "injected outage (admin/fault, since …)"}`; `/healthz` and
`/admin/*` keep working on purpose — the scenario is "the dependency's application fails",
not "its container died", so the container stays healthy in `docker compose ps` and the
worker sees a clean 5xx (→ fail with retries and backoff → incident, see
`workers/booking/README.md`).

The image is `scratch` (no shell, no curl) and the port is not published, so the binary is
its own client, like `-check`:

```bash
# on the VM (infra/)
docker compose exec -T booking-api /app -fault status
docker compose exec -T booking-api /app -fault on          # 503
docker compose exec -T booking-api /app -fault on:500      # any 500..599
docker compose exec -T booking-api /app -fault off
# from the workstation (STAND_HOST set): make fault-on [STATUS=500] | fault-off | fault-status
```

Each command prints the resulting state as JSON and exits 0; the server logs `fault ON …` /
`fault OFF`. `tests/smoke/phase-6-infra.sh` runs the on/off round-trip.

## Run

Part of the `integrations` compose profile (`infra/docker-compose.yml`); the image is built
on the VM by `make deploy`. The port is not published — the service is reachable as
`http://booking-api:8080` inside the compose network only.

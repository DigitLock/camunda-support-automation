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

Booking fields: `id`, `customerId`, `value`, `currency`, `bookedAt`, `travelDate`, `status`.

Seed data: `BK-77`, `BK-81`, `BK-90` (EUR, aligned with `tests/e2e/tickets.json`) and
`BK-1001` (USD 1200, used by the FX conversion path and the smoke test).

## Deterministic failures (by booking id)

| ID | Behaviour |
|---|---|
| `BK-FAIL-500` | immediate 500 |
| `BK-FAIL-TIMEOUT` | responds only after 30 s (the client is expected to time out first) |
| any unknown id | 404 |

## Run

Part of the `integrations` compose profile (`infra/docker-compose.yml`); the image is built
on the VM by `make deploy`. The port is not published — the service is reachable as
`http://booking-api:8080` inside the compose network only.

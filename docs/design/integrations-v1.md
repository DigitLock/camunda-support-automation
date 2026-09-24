# Integrations v1 — design (Phase 4)

**Status:** in progress — infrastructure (step 4.1) is in place; D4 decisions are recorded
here as they are made during 4.2–4.x.

Related: ADR-005 (Kafka), ADR-006 (containers and profiles), ADR-007 (Kafka via Connectors),
`process-v1.md`, `routing-v1.md`.

## 1. Kafka

Single-node KRaft broker (`apache/kafka`, pinned in `infra/docker-compose.yml`), compose
profile `integrations`, no authentication (stand limitation — `docs/ops/install.md`).

| Topic | Direction | Producer | Consumer |
|---|---|---|---|
| `support.ticket.created` | in | e2e scripts / external systems | inbound Kafka connector → starts `support-request-v1` |
| `support.ticket.resolved` | out | outbound Kafka connector task | e2e verification, downstream systems |

Listeners: `INTERNAL` `kafka:29092` for connectors and workers inside the compose network;
`EXTERNAL` host port `9092`, advertised address from `STAND_IP` (`infra/.env`) for clients
outside the VM. Topics are created by the one-shot `kafka-init` container.

Connector wiring (element templates, message mapping, error handling): to be designed in 4.2.

## 2. Booking API

Mock service `services/booking-api` (compose profile `integrations`, in-network only,
`http://booking-api:8080`). Contract and the deterministic-failure convention
(`BK-FAIL-500`, `BK-FAIL-TIMEOUT`, unknown → 404): see `services/booking-api/README.md`.
Consumed by the `booking.change` / `booking.cancel` Go workers from 4.2; the failure ids
drive the incident-handling scenarios in Phase 6.

## 3. FX

`services/fx-gateway` (profile `integrations`, `FX_BASE_URL=http://fx:8080`), called by the
REST connector for currency-aware refund decisions (the `bookingValue > 1000` threshold from
`routing-v1.md` D3-7 becomes currency-aware here).

Contract: `GET /convert?from=USD&to=EUR&amount=1200` →
`{"from","to","amount","rate","converted","asOf"}`. Provider behind a `RateProvider`
interface — currently frankfurter.app (ECB rates, no RSD, needs outbound internet); the swap
to the shared currency-rate-service is parked in `docs/backlog.md` and does not change the
contract.

## 4. Idempotency

To be designed in 4.2–4.3. Established pieces so far:

- Message start events do not open a new instance while an active instance with the same
  correlation key exists (`process-v1.md` §6); `correlationKey = ticketId`.
- The e2e scripts disambiguate runs with `messageId = <ticketId>-<RUN_ID>`.
- The inbound Kafka connector delivers at-least-once (ADR-007) — the dedup strategy for
  redelivered `ticket.created` events (messageId from the Kafka record, TTL) is the open
  question for 4.2.

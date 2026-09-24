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

Connector wiring (process v5, step 4.3): the Kafka Message Start Event Connector is the
**only** way an instance starts, and `publish-resolved` produces the outcome — exact element
properties in `process-v1.md`, "v5 changes".

| ID | Decision | Rationale |
|---|---|---|
| D4-4 | The Kafka start event connector replaces REST message publication as the only process entry | One entry path, one dedup mechanism; the e2e producer becomes a real external system |
| D4-5 | Dedup key is the `messageId` field of the event payload, connector expression `=value.messageId`; Message TTL `PT1H` | The producer controls idempotency (`<ticketId>-<runId>`); the TTL bounds the dedup window so deliberate re-sends (incident drills) work after an hour |

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

Same-currency short-circuit: `from == to` returns `rate: 1`, `converted = amount`, `asOf` =
today, **without a provider call** — EUR-only tickets work offline and any currency code is
accepted when it converts to itself.

Process v5 uses two conversions: `convert-booking-value` (booking `currency` → EUR →
`bookingValueEur`, the `sla-policy` DMN input per D3-7) and `convert-refund` (see Refund).

## 4. Refund

`booking.cancel` completes with `refundAmount` (= the booking's `value`) and
`refundCurrency` (= the booking's `currency`) taken from the Booking API response. The
process then converts the refund into the customer's payout currency:
`convert-refund` calls the FX gateway with `from=refundCurrency`, `to=customerCurrency`,
`amount=refundAmount` and stores `refundAmountCustomer`. Same-currency refunds hit the
short-circuit and stay deterministic.

## 5. Workers (Phase 4.2)

`workers/booking` (Go, stdlib, REST API v2 long polling) serves `booking.change` and
`booking.cancel`; the Python stub keeps `ticket.classify`, `ticket.answer`, `ticket.notify`.
Both run as containers in the `workers` compose profile (ADR-006). Output variables are
unchanged against the Phase 2 stub, plus `bookingStatus` from the Booking API response.

| ID | Decision | Rationale |
|---|---|---|
| D4-1 | Error contract: Booking API 2xx → complete with `{bookingStatus}`; 404 **or missing/null `bookingRef`** → BPMN error `BOOKING_NOT_FOUND`; 5xx or client timeout (10 s) → fail with `retries - 1` and errorMessage | Business absence is a modelled path, infrastructure trouble is a retry and then an incident; the missing-ref case cannot reach the API and is business absence too |
| D4-2 | One binary serves both booking job types | Same dependency, same error contract; two polling loops inside one process cost less than two containers |
| D4-3 | `/healthz` is age-based: 200 while the last successful activation poll (empty responses count) is < 60 s old | A worker that cannot reach the engine is unhealthy even though its process lives; job timeout 60 s covers the mock API's 30 s injected delay |

## 6. Idempotency

To be designed in 4.2–4.3. Established pieces so far:

- Message start events do not open a new instance while an active instance with the same
  correlation key exists (`process-v1.md` §6); `correlationKey = ticketId`.
- The e2e scripts disambiguate runs with `messageId = <ticketId>-<RUN_ID>`.
- The inbound Kafka connector delivers at-least-once (ADR-007) — the dedup strategy for
  redelivered `ticket.created` events (messageId from the Kafka record, TTL) is the open
  question for 4.2.

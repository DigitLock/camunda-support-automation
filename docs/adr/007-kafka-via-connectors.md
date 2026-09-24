# ADR-007: Kafka inbound/outbound through Camunda Connectors

- **Status:** Accepted
- **Date:** 2026-09-24

## Context

Tickets enter the stand as `support.ticket.created` events and leave as
`support.ticket.resolved` (ADR-005). Two ways to bridge Kafka and the process:

1. **Camunda Kafka Connector** — the Connectors runtime already runs in the core profile;
   inbound consumption and outbound production are configured in the BPMN model via element
   templates, no code.
2. **Own Go kafka-bridge** — a consumer/producer using the thin REST client (the original
   architecture sketch), full control over semantics, but code, tests and operations to own.

## Decision

Kafka in and out goes through **Camunda Connectors**: an inbound Kafka connector consumes
`support.ticket.created` and starts/correlates process instances; an outbound Kafka connector
task publishes `support.ticket.resolved`. The own Go consumer is **parked in the backlog**,
to be revived only if connector semantics prove insufficient.

## Consequences

- No bridge code to write and operate; Kafka wiring is visible in the model and in Operate.
- The Connectors runtime needs Kafka access: same compose network, INTERNAL listener,
  no auth (stand limitation, see `docs/ops/install.md`).
- Delivery semantics are the connector's (at-least-once, connector-managed retries);
  idempotency has to be handled on the process side — design in
  `docs/design/integrations-v1.md`.
- The README architecture sketch still shows a `kafka-bridge` worker; it gets corrected at
  the Phase 4 close.

## Revisit when

- The flow needs semantics the connector does not offer: dead-letter queues, batching,
  transactional produce, or schema-registry payloads.

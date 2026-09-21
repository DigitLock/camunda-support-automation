# ADR-005: Message broker

- **Status:** Accepted
- **Date:** 2026-09-21

## Context

Tickets enter the process as `support.ticket.created` events and leave as
`support.ticket.resolved`. The stand has to come up from the repository alone, and RAM is not a
constraint on the target VM.

## Decision

- **Apache Kafka in KRaft mode, single node**, official `apache/kafka` image, in the
  `integrations` Compose profile, with a web UI for inspection.
- The Kafka version is pinned at the start of Phase 4.

## Consequences

- Real Kafka semantics and tooling; docs can say "Kafka" without qualifiers.
- Single broker: no replication, not a durability reference.

## Alternatives considered

- **Redpanda** — lighter and Kafka-API compatible; unnecessary here since RAM is available, and
  it would add a "compatible with" footnote.
- **An existing broker elsewhere in the homelab** — an external dependency outside the repository
  breaks reproducibility and portability.

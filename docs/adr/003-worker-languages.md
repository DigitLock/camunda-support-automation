# ADR-003: Job worker languages and client strategy

- **Status:** Accepted
- **Date:** 2026-09-21

## Context

Officially maintained clients in 8.9: Java, Spring, Node.js/TypeScript and the Python SDK; C# is a
technical preview. The Go client and `zbctl` were deprecated with 8.6 and handed to the community;
the CLI successor is `c8ctl`, built on the Orchestration Cluster REST API.

The author's working languages are Go and Python. The stand may be reached through an HTTP reverse
proxy or tunnel, where gRPC is a known source of trouble.

## Decision

- **LLM classifier — Python** with the official `camunda-orchestration-sdk` (long-polling job
  workers, Basic auth).
- **Integration workers, mock Booking API, Kafka bridge — Go**, without a Camunda client library.
  A thin internal package `workers/internal/camunda` wraps the REST API: activate jobs
  (long polling), complete, fail with retries and backoff, throw BPMN error, publish message.
  Request/response types are generated from the official OpenAPI specification.
- **REST only.** No gRPC anywhere; the gateway gRPC port stays unpublished.
- **Time-box:** if the Go worker runtime is not stable by the end of Phase 2, integration workers
  move to the Python SDK and Go stays in the mock API and the Kafka bridge.

## Consequences

- We own a small worker runtime (polling loop, concurrency limit, graceful shutdown); it needs
  its own tests.
- Working at the API level makes the job lifecycle explicit — the same knowledge needed to
  diagnose incidents in Operate.
- Everything passes through plain HTTP infrastructure.

## Alternatives considered

- **Community Go gRPC client** — no vendor support since 8.6, and brings gRPC back.
- **Python for everything** — the fallback, see time-box.
- **Java/Spring** — the mainstream choice for Camunda workers, but not the author's stack.

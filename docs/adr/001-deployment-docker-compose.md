# ADR-001: Single-node Docker Compose deployment

- **Status:** Accepted
- **Date:** 2026-09-21

## Context

The stand must be a reproducible Camunda 8 Self-Managed environment on one Proxmox VM, built and
documented in about two weeks by one person.

Camunda supports its Docker images for production use, but positions the published Docker Compose
files as a local development tool; the reference production path is Kubernetes with Helm. In the
8.9 Helm chart the PostgreSQL, Elasticsearch and Keycloak sub-charts are disabled by default, so a
Kubernetes setup also means provisioning that infrastructure through operators or external services.

## Decision

- Dedicated Debian VM: 6 vCPU, 16 GiB RAM (no ballooning), 100 GB on local NVMe.
- Our own `infra/docker-compose.yml`, derived from the official `docker-compose-8.9` distribution,
  split into profiles:
  - `core` — Orchestration Cluster, Connectors, Elasticsearch
  - `integrations` — Kafka, PostgreSQL, mock Booking API, job workers
  - `monitoring` — Prometheus, Grafana
  - `upgrade-lab` — disposable 8.8 stack for the minor-upgrade rehearsal (ADR-002)
- Security baseline: built-in Identity, Basic auth, protected API, authorizations enabled,
  dedicated users for workers and Connectors.
- The gateway gRPC port is not published; every client uses the REST API (ADR-003).
- Wording used across the docs: *production-grade practices on a single-node Compose deployment* —
  pinned versions, protected API, backups, monitoring, upgrade procedure. It is not called a
  production deployment.

## Consequences

- `docker compose up` from a clean VM is the acceptance test for the install guide.
- No high availability: one broker, one partition, one Elasticsearch node.
- The Kubernetes/Helm path is described in the lessons learned, not implemented.

## Alternatives considered

- **k3s + Helm from day one** — closest to the reference production path, but infrastructure
  provisioning would consume days that belong to process, integration and operations work.
  Kept as a stretch goal after the final phase.
- **Camunda 8 Run** — development distribution only.
- **Camunda SaaS** — removes exactly the self-managed operations this project is about.

# ADR-006: Workers and services run as containers in the stand's Compose file

- **Status:** Accepted
- **Date:** 2026-09-24

## Context

Phase 4 adds the mock Booking API, the FX gateway and Go job workers. The Phase 2 Python stub
worker runs in a venv on the VM, started by hand: no restart policy, no healthcheck, and one
root-ownership accident already documented in `docs/ops/install.md` (rsync error 23). The
stand must come up from the repository alone (ADR-001).

## Decision

- All Phase 4+ services and workers run as containers in `infra/docker-compose.yml`.
- Profiles group services by role:
  - `integrations` — everything the **process** depends on: Kafka, the topic init container,
    mock Booking API, FX gateway, the smoke-test helper;
  - `workers` — **job workers only**; empty until Phase 4.2, when the Go workers arrive and
    the Python stub migrates in.
- Images are built on the VM by `make deploy` (`docker compose ... up -d --build`), tagged
  `:local`; no image registry.
- Service images are `scratch`-based with static Go binaries; healthchecks run the binary's
  own `-check` flag because scratch has no shell.

## Consequences

- One command brings up platform + integrations; restart policies and healthchecks apply to
  everything uniformly.
- The VM spends CPU on image builds during deploy; acceptable at this scale.
- Core services carry no `profiles:` key, so plain `docker compose up -d` still works
  unchanged (install guide, upgrade lab).
- Until Phase 4.2 the stub worker remains a venv process — the one exception, documented in
  its README.

## Revisit when

- A registry/CI pipeline appears (build on push instead of on the VM), or the k3s stretch
  goal from ADR-001 is picked up.

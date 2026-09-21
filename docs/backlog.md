# Backlog

Ideas parked here to keep the current phase focused. Each entry names the phase it could fit into.

## Parked ideas
   - **Phase 4 — Currency Rate Service as the external FX dependency.** The service is gRPC-only
     and not deployed yet. Work in its own repository: (1) `google.api.http` annotations and
     grpc-gateway on the existing HTTP port, (2) multi-stage Dockerfile, (3) Compose deployment on
     the shared Docker host with its own PostgreSQL (no published port) and migrations, (4) curl
     verification. Consumed through `FX_BASE_URL`. Time-box: half a day; fallback — the REST
     connector calls a public FX API directly.
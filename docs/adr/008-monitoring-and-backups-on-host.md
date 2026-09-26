# ADR-008: Monitoring and backups stay on the stand VM

- **Status:** Accepted
- **Date:** 2026-09-25

## Context

Phase 6 adds monitoring, backup/restore and incident handling to a single-node Compose
stand (ADR-001). A monitoring host or an off-host backup target would each need a second
machine or an object store with credentials. The project demonstrates operational
procedures, not infrastructure provisioning, and the VM has 16 GiB shared with
Elasticsearch, the Orchestration Cluster, Kafka and PostgreSQL.

## Decision

- **Monitoring** is the `monitoring` compose profile on the stand VM: Prometheus scrapes
  the Orchestration Cluster's management endpoint (`:9600/actuator/prometheus`, not
  published), Grafana (port 3000) shows a provisioned dashboard. One alert rule,
  `incidents > 0`, evaluated by Prometheus and visible in Grafana. No Alertmanager, no
  notification channel.
- **Backups** go to the VM's local disk: an Elasticsearch `fs` snapshot repository and an
  orchestration `FILESYSTEM` backup store under `/var/backups/camunda`. Off-host copies are
  out of scope; the backup runbook states this limitation explicitly.
- The SLA demo variable `slaOverride` (design D6-3) is a process concern and recorded in
  `docs/design/operations-v1.md`, not here.

## Consequences

- A lost VM loses the backups with the data. The rehearsed procedures (order, backup ids,
  pause/resume, restore with the same version) transfer unchanged to an S3/GCS store —
  that is a store-type property and credentials.
- Alerts are pulled (Grafana, Prometheus UI), never pushed. Someone has to look.
- Monitoring shares the VM's memory budget: about 1 GiB for both containers.

## Alternatives considered

- **Separate monitoring VM** — realistic, but the demo would be about network paths and
  a second install guide; the metrics and the alert rule are identical.
- **MinIO on the stand as an S3 backup target** — exercises the S3 store type, but a
  bucket on the same disk protects against exactly as much as a directory does.
- **Alertmanager with a mail/webhook receiver** — no receiver exists in the lab; a
  notification to nowhere demonstrates nothing.

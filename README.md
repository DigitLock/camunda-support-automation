# Camunda Support Automation

Status: in progress — see the phase table.

A customer support automation stand on **Camunda 8.9 Self-Managed**: a BPMN ticket process with
DMN/FEEL routing, an LLM classifier with guardrails (Claude API, JSON Schema validation, keyword
fallback), REST and Kafka integrations, and an operations layer — install, monitoring, backup,
instance migration and a rehearsed minor upgrade. The stand comes up from this repository on a single Docker Compose VM. Architecture decisions live in [`docs/adr/`](docs/adr/).

## Architecture

```mermaid
flowchart LR
    subgraph external["External"]
        claude["Claude API"]
        fx["FX rate service"]
    end

    subgraph vm["Single VM — Docker Compose"]
        subgraph core["core profile"]
            camunda["Orchestration Cluster<br/>(camunda/camunda 8.9)<br/>Zeebe + Operate + Tasklist + Admin"]
            connectors["Connectors 8.9"]
            es[("Elasticsearch<br/>secondary storage")]
        end
        subgraph integrations["integrations profile"]
            kafka["Kafka (KRaft, single node)"]
            bridge["kafka-bridge (Go)"]
            booking["booking-adapter (Go)"]
            notifier["notifier (Go)"]
            mockapi["mock Booking API (Go)"]
            classifier["llm-classifier (Python SDK)"]
            pg[("PostgreSQL<br/>audit + analytics")]
        end
        subgraph monitoring["monitoring profile"]
            prom["Prometheus"]
            graf["Grafana"]
        end
    end

    kafka -- "support.ticket.created" --> bridge
    notifier -- "support.ticket.resolved" --> kafka
    bridge -- "REST v2: publish message" --> camunda
    classifier -- "REST v2: long-poll jobs" --> camunda
    classifier --> claude
    classifier -- "audit" --> pg
    booking -- "REST v2: long-poll jobs" --> camunda
    booking -- "HTTP/JSON" --> mockapi
    notifier -- "REST v2: long-poll jobs" --> camunda
    camunda --> es
    connectors --> camunda
    prom --> camunda
    graf --> prom
    connectors -- "REST connector" --> fx
```

All clients use the **Orchestration Cluster REST API (v2)** with Basic auth; the gRPC port is not
published. Go workers share a thin REST client in `workers/internal/camunda`.

## Repository layout

```
infra/              Docker Compose, config, disposable upgrade-lab stack
processes/          BPMN models
decisions/          DMN models
forms/              Camunda Forms
connectors/         Connector templates and configuration
workers/            Job workers (Go) + llm-classifier (Python) + shared REST client
services/           Mock Booking API
prompts/            Versioned classifier prompts with labelled test set
tests/              DMN and classification test cases
docs/               Design, ops guides, runbooks, analytics, ADRs
```

## Phases

| # | Phase | Status |
|---|-------|--------|
| 0 | Scope & repo | done |
| 1 | Platform | in progress |
| 2 | Process v1 happy path | planned |
| 3 | DMN + FEEL | planned |
| 4 | Integrations | planned |
| 5 | LLM classifier with guardrails | planned |
| 6 | Operations | planned |
| 7 | Docs & analytics | planned |
| 8 | Publication | planned |

## Daily status

One line per day: date — phase — done / broken / next.

- 2026-09-21 — Phase 0 done, Phase 1 nearly done — VM + Docker; core stack (Camunda 8.9.21 / Connectors 8.9.12 / ES 8.19.11) up in under a minute; protected API with Basic auth and authorizations; smoke test via REST + Tasklist + Operate; install guide / ES yellow on single node (replicas 0); sysctl override lowered the Debian 13 default (removed); VM time zone (UTC); config edited but not synced before restart (make deploy) / install-from-scratch run against docs/ops/install.md, then Phase 2
- 2026-09-22 — Phase 1 done — install-from-scratch run against docs/ops/install.md passed in <N> min; one doc gap (ssh config block was not a command) fixed / stand broke overnight before the run was finished (restarted from the clean snapshot) / Phase 2: process v1 happy path

## License note

The stand runs **without a Camunda license key**, i.e. as non-production use — the components show
"Non-production license" and "Non-commercial license" badges, with no functional limits. Applying for Camunda's
**non-commercial license** is planned after publication (see `docs/backlog.md`); until then the
banner stays visible in screenshots. This project demonstrates production-grade practices
(pinned versions, protected API, backups, monitoring, upgrade procedure) on a single-node
deployment; it is not a production deployment.


To bring the stand up from an empty VM, follow [`docs/ops/install.md`](docs/ops/install.md).
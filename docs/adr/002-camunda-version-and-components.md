# ADR-002: Camunda version, components and secondary storage

- **Status:** Accepted
- **Date:** 2026-09-21
- **Amended 2026-09-21:** pins follow the official `docker-compose-8.9` distribution
  (camunda/camunda-distributions, commit bf243ed): Camunda 8.9.21, Connectors 8.9.12,
  Elasticsearch 8.19.11.

## Context

- 8.9 is the current stable minor (released April 2026, standard maintenance until October 2027).
  Latest patches at decision time: Camunda 8.9.19, Connectors 8.9.10. 8.10 is unreleased.
- Since 8.8 Zeebe, Operate, Tasklist and Identity ship as one Orchestration Cluster application;
  since 8.9.12 only the unified `camunda/camunda` image is published.
- 8.9 adds RDBMS (e.g. PostgreSQL) as secondary storage next to Elasticsearch/OpenSearch. Both are
  valid production choices. The 8.9 lightweight Compose setup defaults to H2. Optimize works only
  with Elasticsearch/OpenSearch.
- Licensing: since 8.6, production use of Self-Managed requires a license key. Without a key the
  components show a "Non-Production License" banner and log warnings, with no functional limits.

## Decision

- Pin **Camunda 8.9.19** and **Connectors 8.9.10** by tag and digest in `.env`. The Elasticsearch
  version is taken from the `.env` of the official `docker-compose-8.9` distribution.
- **Elasticsearch** as secondary storage, enabled explicitly.
  *Assumption:* RDBMS secondary storage is only a few months old, so existing production
  installations run on Elasticsearch/OpenSearch, and that is the operational surface worth
  practising — exporter lag, disk watermarks, snapshot-based backup.
- **No Optimize.** It ships only in the full configuration together with Management Identity and
  Keycloak. Process metrics are pulled through the REST API into PostgreSQL and analysed with SQL.
- **Upgrades.** The main stand starts on 8.9.19. The minor upgrade (8.8.x → 8.9.19) is rehearsed
  on the disposable `upgrade-lab` stack with unfinished process instances. If a newer 8.9 patch
  appears during the project, the main stand gets a patch upgrade under the same runbook.
- **License.** The stand runs without a key as non-production use; the README says so up front,
  because the banner is visible in every screenshot.

## Consequences

- Elasticsearch needs host tuning (`vm.max_map_count`) and takes the largest share of RAM.
- Analytics need a small export job instead of Optimize dashboards.
- Two Camunda configurations exist in the repo (8.9 main, 8.8 lab); the lab one is isolated in
  its own directory and profile.

## Alternatives considered

- **PostgreSQL as secondary storage** — lighter and simpler, but new in 8.9 and not what
  established installations run. Noted as a migration option.
- **H2** — development default only.
- **Start the main stand on 8.8 and upgrade in place** — unified configuration was only partly
  introduced in 8.8 and completed in 8.9; a week of development on property names that are
  remapped afterwards is avoidable risk.

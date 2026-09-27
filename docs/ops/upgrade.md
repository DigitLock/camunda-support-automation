# Upgrade

Patch upgrades of the Orchestration Cluster and the Connectors on the stand, and how they
are rehearsed. Design: `docs/design/operations-v1.md` §6, ADR-002. Backups:
`docs/runbooks/backup-restore.md`.

**Status:** patch path rehearsed on the lab 2026-09-27 (8.9.19 → 8.9.21, §3 *Observed*);
the main stand is not upgraded because no newer 8.9.x exists (§1). The minor-upgrade path
8.8 → 8.9 is **not** rehearsed (`docs/lessons-learned.md`).

## 1. Facts

- Versions are pinned in `infra/.env`: `CAMUNDA_VERSION` (image `camunda/camunda`),
  `CAMUNDA_CONNECTORS_VERSION` (`camunda/connectors-bundle`), `ELASTIC_VERSION` — never
  `latest`. Orchestration and Connectors move together within a minor; Elasticsearch stays.
- Newest 8.9.x on Docker Hub (checked 2026-09-27): `camunda/camunda` **8.9.21**,
  `connectors-bundle` **8.9.12** — the stand's pins. **8.9.20 was never published**; GitHub
  has no 8.9.22 release (connectors: 8.9.13-rc3, prerelease). There is nothing to upgrade
  the main stand to today, so the patch path is rehearsed on the lab instead.
- A backup can only be restored on the exact version it was taken with. The pre-upgrade
  backup is therefore the rollback point **for the old version**, together with the pin.

## 2. Patch upgrade of the main stand (procedure)

Window without running instances preferred (`verify-state.sh` shows `instances ACTIVE 0`).

1. **Pre-checks** (stand host, `infra/`): `docker compose ps` all healthy;
   `tests/ops/verify-state.sh > /tmp/state-before.txt`; Proxmox snapshot of the VM
   (host side, outside this repo).
2. **Backup**: `tests/ops/backup.sh` — note the id.
3. **Pin** (workstation): in `infra/.env.example` and the stand's `infra/.env` (root):

   ```diff
   -CAMUNDA_VERSION=8.9.21
   +CAMUNDA_VERSION=8.9.<new>
   -CAMUNDA_CONNECTORS_VERSION=8.9.12
   +CAMUNDA_CONNECTORS_VERSION=8.9.<matching>
    ELASTIC_VERSION=8.19.11            # untouched
   ```

4. **Roll out**: `make deploy` (pulls the new images, recreates `orchestration` and
   `connectors`; workers are rebuilt but unchanged).
5. **Verify**: `curl … /v2/topology` shows the new `gatewayVersion` and broker version
   (f-01); the verification block of `install.md`; `tests/e2e/send-tickets.sh` and
   `--check` 8/8 (f-02); `verify-state.sh` matches the pre-upgrade output.
6. **Rollback** (symptom → check → action):
   - the cluster does not become healthy, or the topology shows the old version → check
     `docker compose logs orchestration` for a migration or configuration error → pin back
     in `.env`, `make deploy`; if the data was touched by the new version, restore the
     pre-upgrade backup with `tests/ops/restore.sh <id>` **on the old pin**; the Proxmox
     snapshot is the last resort.
   - e2e fails after the upgrade → check the worker logs and `--incidents` → same rollback.

**Observed:** not yet run — nothing newer than 8.9.21 / connectors 8.9.12 is published
(§1). The procedure was exercised on the lab instead (§3).

## 3. Rehearsal on the lab (8.9.19 → 8.9.21)

**Lab layout.** The same compose file under project `camunda-lab`, containers
`lab-orchestration` and `lab-elasticsearch`, network `camunda-lab`, port **18080**, data
under `/srv/camunda-lab/{camunda,elastic,backups/zeebe,backups/es}`, pinned one patch
behind the stand in `infra/upgrade-lab/.env.lab` (from `.env.lab.example`: 8.9.19,
connectors 8.9.10, Elasticsearch 8.19.11 as on the stand). Only `elasticsearch` and
`orchestration` run (`infra/upgrade-lab/lab.override.yml`); no workers, no Kafka, no
connectors. Driven by `tests/ops/upgrade-lab.sh`.

**Rule: the main stand is stopped for the whole lab session; lab and stand never run
together.** The VM has 16 GiB, and `upgrade-lab.sh up` refuses to start while the main
stand has running containers. `docker compose stop` (not `down`) keeps the stand's volumes;
`docker compose start` brings it back unchanged.

Root, once: `mkdir -p /srv/camunda-lab/{camunda,elastic,backups/zeebe,backups/es}`, then `chown 1001:1001 /srv/camunda-lab/camunda /srv/camunda-lab/backups/zeebe` and `chown 1000:1000 /srv/camunda-lab/elastic /srv/camunda-lab/backups/es` (the camunda image runs as uid 1001, elasticsearch as 1000);
copy `infra/upgrade-lab/.env.lab.example` to `infra/upgrade-lab/.env.lab` and set the two
passwords. Compose ≥ 2.24 is needed for the `!override` tags in the lab override.

```bash
cd /opt/camunda-support-automation/infra
docker compose stop                                   # main stand off (RAM)
../tests/ops/upgrade-lab.sh up                        # 8.9.19, topology printed
../tests/ops/upgrade-lab.sh seed                      # deploys BPMN + DMN + forms, starts 3 instances waiting at classify-ticket
../tests/ops/upgrade-lab.sh state                     # record: version, definitions, ACTIVE instances, CREATED jobs
../tests/ops/upgrade-lab.sh upgrade 8.9.21 8.9.12     # re-pin, pull, up -d, topology, instances, jobs activatable
../tests/ops/upgrade-lab.sh state                     # again, ≥ 90 s later
../tests/ops/upgrade-lab.sh down
docker compose start                                  # main stand back
```

Expected: after `upgrade`, the topology reports 8.9.21, the three instances are still
ACTIVE, and a job activation returns their `ticket.classify` jobs — the instances are
resumable. Rollback in the lab = `upgrade 8.9.19 8.9.10` (pin back) plus, if the data does
not come up, wipe `/srv/camunda-lab` and start over.

**Observed 2026-09-27** (8.9.19 → 8.9.21, connectors pin 8.9.12; raw run output
`lab-f-01.txt`, `lab-upgrade.log`, `lab-f-02.txt` kept on the VM, not in the repository):

- `up`: images pulled, `lab-elasticsearch` and `lab-orchestration` healthy in ~40 s. The
  step ended with `jq: error (at <stdin>:0): Cannot iterate over null` — cosmetic, fixed
  below.
- `seed`: 8 resources deployed (process, DMN, forms), 3 instances of `support-request-v1`
  started at `classify-ticket`, 3 `ticket.classify` jobs CREATED — there is no worker in
  the lab by design; the waiting jobs are the running work that has to survive.
- `state` before the upgrade (f-01, verbatim; pre-fix output, see the script fixes below):

  ```
  {"gatewayVersion":"8.9.19","brokers":[{"version":"8.9.19","health":null}]}
  definitions: [1]
  instances ACTIVE: ["2251799813685331","2251799813685346","2251799813685361"]
  jobs CREATED (ticket.classify): 3
  ```

- `upgrade 8.9.21 8.9.12`: pin rewritten in `.env.lab`, `orchestration` recreated, healthy
  in ~20 s; then (`lab-upgrade.log`, tail):

  ```
  19:12:43 lab-orchestration healthy
  {"gatewayVersion":"8.9.21","brokers":["8.9.21"]}
  instances ACTIVE after upgrade: ["2251799813685331","2251799813685346","2251799813685361"]
  activated jobs: [{"jobKey":"2251799813685345","processInstanceKey":"2251799813685331"},{"jobKey":"2251799813685360","processInstanceKey":"2251799813685346"},{"jobKey":"2251799813685375","processInstanceKey":"2251799813685361"}]
  ```

  The same three instance keys are ACTIVE on 8.9.21 and the probe worker activated their
  jobs — the instances are resumable after the upgrade.
- `state` 90 s after the upgrade (f-02, verbatim):

  ```
  {"gatewayVersion":"8.9.21","brokers":[{"version":"8.9.21","health":null}]}
  definitions: [1]
  instances ACTIVE: ["2251799813685331","2251799813685346","2251799813685361"]
  jobs CREATED (ticket.classify): 0
  ```

  **`jobs CREATED 0` is not a loss.** The `upgrade` step activated the three jobs as its
  liveness proof (`timeout: 10000` in the activation request), so at that moment they are
  ACTIVATED, not CREATED; after the job timeout they become CREATED again. Read f-01 vs
  f-02 through `instances ACTIVE`, which is the state check.
- `down`, then `docker compose start` on the main stand and `tests/smoke/phase-6-backup.sh`:
  all checks passed. Lab data still under `/srv/camunda-lab` (wipe as root when done).

**Script fixes from the run** (`tests/ops/upgrade-lab.sh`, cosmetic, one line each, applied
2026-09-27 after the run — the excerpts above show the pre-fix output):

| Symptom in the run | Cause | Fix |
|---|---|---|
| `up` ends with `jq: error (at <stdin>:0): Cannot iterate over null` | `.brokers` is null in `/v2/topology` for a moment after the container turns healthy | `(.brokers // [])[]` in `up` and `upgrade` |
| `seed` prints `"version":null` for the process | in the 8.9 v2 deployment response a process carries `processDefinitionVersion`; DMN and forms carry `version` | `version: (.version // .processDefinitionVersion)` |
| `state` prints `"health":null` for the broker | `BrokerInfo` has no `health` field in 8.9 v2; health is reported per partition | `state` prints `partitions: [{partitionId, role, health}]` per broker |

Not rehearsed: the minor path 8.8 → 8.9 — the stand started on 8.9, so ADR-002's 8.8 lab is
superseded by this patch-path lab (`docs/lessons-learned.md`).

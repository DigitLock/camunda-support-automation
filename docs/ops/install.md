# Installation guide

From an empty Proxmox VM to a verified core stack. Every command is meant to be copy-pasted in
order; nothing here depends on context outside this repository.

## Prerequisites

VM parameters (ADR-001):

- 6 vCPU, 16 GiB RAM with ballooning **disabled**, 100 GB disk on local NVMe
- disk flags: `discard=on`, `ssd=1`
- QEMU guest agent enabled in the VM options

Debian 13 installer choices:

- hostname: `camunda-stand` (or your own — it only has to match the SSH config below)
- one unprivileged user (used later as the sync user)
- software selection: **no** desktop environment, **SSH server**, **standard system utilities**

## VM preparation

All commands as root on the VM.

```bash
# guest agent (static unit — no `enable` needed, it starts via udev)
apt-get update && apt-get install -y qemu-guest-agent
systemctl is-active qemu-guest-agent

# base tools (rsync is required by `make sync`) and Docker CE from the official repository
apt-get install -y ca-certificates curl rsync jq
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
docker compose version

# container log rotation
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" }
}
EOF
systemctl restart docker

# kernel settings: minimise swapping; do NOT touch vm.max_map_count on Debian 13
# (it already ships 1048576 — see Troubleshooting)
echo 'vm.swappiness=1' > /etc/sysctl.d/99-camunda.conf
sysctl --system
sysctl vm.swappiness vm.max_map_count   # expect 1 and 1048576

# TRIM for the thin-provisioned disk, UTC everywhere
systemctl enable --now fstrim.timer
timedatectl set-timezone UTC
```

Backup directories (Phase 6.4, ADR-008): host bind mounts, never docker volumes, so a
`docker compose down -v` cannot take the backups with the data. Owners are the container
users, **confirmed on the stand 2026-09-27**: uid **1001** for `camunda/camunda` (the
`camunda` user), uid 1000 for `elasticsearch`, uid 70 for `postgres:alpine`.

```bash
mkdir -p /srv/camunda-backups/es /srv/camunda-backups/zeebe /srv/camunda-backups/pg
chown 1000:1000 /srv/camunda-backups/es
chown 1001:1001 /srv/camunda-backups/zeebe
chown 70:70 /srv/camunda-backups/pg
```

The directory is root-owned, so the deploy user cannot write there (`tee` to it fails);
script logs go to `/tmp`. `pg_dump` runs as root inside the postgres container, so the dump
files are `root:root` — normal.

## Sync setup

The repository is synced from the workstation, not cloned on the VM. As root on the VM
(`<user>` is the unprivileged user from the installer):

```bash
mkdir -p /opt/camunda-support-automation
chown <user>: /opt/camunda-support-automation
usermod -aG docker <user>      # takes effect on next login

# optional, for root: make `docker compose ...` work from any directory
echo 'export COMPOSE_FILE=/opt/camunda-support-automation/infra/docker-compose.yml' >> /root/.bashrc
```

On the workstation, add an alias to `~/.ssh/config` (replace the placeholders), install your
key and point `STAND_HOST` at the alias:

```bash
cat >> ~/.ssh/config <<'EOF'
Host camunda-stand
    HostName <vm address>
    User <user>
EOF
ssh-copy-id camunda-stand
export STAND_HOST=camunda-stand
make sync     # rsync the repo to /opt/camunda-support-automation (excludes .git and .env)
```
`make deploy` (sync + `docker compose up -d --wait` over SSH) is for later changes, after the
first start below.

## Bringing up the stack

On the VM, create the environment file and start the core stack:

```bash
cd /opt/camunda-support-automation/infra
cp .env.example .env
# generate the two user passwords in place (keep the rest of the placeholders as needed)
sed -i "s|^CAMUNDA_ADMIN_PASSWORD=.*|CAMUNDA_ADMIN_PASSWORD=$(openssl rand -base64 24)|" .env
sed -i "s|^CAMUNDA_CONNECTORS_PASSWORD=.*|CAMUNDA_CONNECTORS_PASSWORD=$(openssl rand -base64 24)|" .env
docker compose up -d --wait   # about 1 min on a warm image cache, ~2 min with image pulls
```

Compose refuses to start (`required variable ... is missing a value`) if either password is
still unset — that is intentional (`${VAR:?message}` in the compose file). Variables with a
compose default do **not** fail fast, so a key that is new in `.env.example` can be missing
from the VM's `.env` without any error. Compare the two files after every sync and before a
restore or an upgrade (it prints the keys missing from `.env`; the expected output is empty):

```bash
comm -23 <(grep -o '^[A-Z_]*=' .env.example | sort) <(grep -o '^[A-Z_]*=' .env | sort)
```

Found this way in Phase 6.5: `COMPOSE_PROFILES` on the VM lacked `monitoring` — the profile
had been in `.env.example` since 6.1 and was never enabled (`docs/lessons-learned.md`).

The core services (orchestration, connectors, elasticsearch) have no `profiles:` key, so a plain
`docker compose up -d --wait` starts exactly them. Subsequent code or config changes are rolled
out from the workstation with `make deploy`.

## Verification

On the VM:

```bash
cd /opt/camunda-support-automation/infra

# 1. All three services healthy
docker compose ps

# 2. API is protected: 401 without credentials, topology JSON with them
source .env
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8080/v2/topology   # expect 401
curl -sS -u "admin:$CAMUNDA_ADMIN_PASSWORD" http://localhost:8080/v2/topology | jq   # one broker, partition 1 healthy

# 3. Elasticsearch (not published on the host): status green, every index with rep 0
docker compose exec elasticsearch curl -sS 'http://localhost:9200/_cat/health?h=status'           # green
docker compose exec elasticsearch curl -sS 'http://localhost:9200/_cat/indices?h=health,rep' | sort | uniq -c   # only "green 0"

# 4. Connectors readiness (no published port)
docker compose exec connectors wget -qO- http://localhost:8080/actuator/health/readiness   # {"status":"UP"}

# 5. Smoke test: deploy the smoke-test process and start an instance (authenticated)
curl -sS -u "admin:$CAMUNDA_ADMIN_PASSWORD" -X POST http://localhost:8080/v2/deployments \
  -F "resources=@../processes/smoke-test.bpmn" | jq '.deployments[0].processDefinition.processDefinitionId'   # "smoke-test"
curl -sS -u "admin:$CAMUNDA_ADMIN_PASSWORD" -X POST http://localhost:8080/v2/process-instances \
  -H 'Content-Type: application/json' -d '{"processDefinitionId": "smoke-test"}' | jq .processInstanceKey
```

In a browser, log in as `admin` with `CAMUNDA_ADMIN_PASSWORD` from `infra/.env`:

- `http://<vm-host>:8080/operate` — the `smoke-test` instance is active, waiting at the user task
  "Check Stand"
- `http://<vm-host>:8080/tasklist` — claim and complete the task
- back in Operate the instance shows as completed

The "Non-production license" and "Non-commercial license" badges in the header are expected
(see the README license note).

## Workers

Since Phase 4.2 the job workers run as containers in the `workers` compose profile
(`worker-booking`, `worker-llm-classifier` — named `worker-stub` until Phase 5), built on
the VM by `make deploy`. The `workers` profile **cannot start on its own**: its services
`depends_on` `booking-api` from the `integrations` profile. Both profiles are activated
permanently via `COMPOSE_PROFILES=integrations,workers` in `infra/.env` (see
`.env.example`), so a plain `docker compose up -d --build` — and every other compose
command — sees all services:

```bash
docker compose up -d --build
```

The venv run of the classifier worker (`workers/llm-classifier/README.md`) remains
available as a dev fallback — never run it and the container at the same time, they
compete for the same job types. For the venv run, set `CAMUNDA_BASE_URL`, `CAMUNDA_USER`
and `CAMUNDA_PASSWORD` in the shell (the commented lines of its `.env.example`); in compose
they come from `infra/.env`.

### Worker user (Phase 6.5)

Both workers authenticate as the technical user `worker`, not `admin`
(`docs/design/operations-v1.md` §7). Its password is `CAMUNDA_WORKER_PASSWORD` in
`infra/.env`, the single source for both services (`docker-compose.yml`, `environment` of
`worker-booking` and `worker-llm-classifier`). Users from `application.yaml` apply only to a
fresh secondary storage, so the user is created on the running stand through the REST API:

```bash
# on the VM, once
printf 'CAMUNDA_WORKER_PASSWORD=%s\n' "$(openssl rand -hex 24)" >> .env     # hex: nothing to escape
tests/ops/create-worker-user.sh          # user + one authorization, idempotent, then the proofs
docker compose up -d worker-booking worker-llm-classifier                   # recreate with the new env
```

The authorization is `PROCESS_DEFINITION` / `support-request-v1` with
`UPDATE_PROCESS_INSTANCE` (activate, complete, fail and throw-error for every job of the
process), `READ_USER_TASK` and `UPDATE_USER_TASK` (the `sla.escalate` handler searches the
open agent task and raises its priority). Nothing else: no `READ_PROCESS_DEFINITION`, no
`CREATE_PROCESS_INSTANCE`, no `RESOURCE` or `COMPONENT` permission, so `worker` cannot
deploy, start, cancel or log in to Operate. The script ends with three zero-side-effect
checks: `GET /v2/process-definitions/<key>` as `worker` → 403 and as `admin` → 200
(control, the negative proof), and `POST /v2/user-tasks/search` as `worker` → 200, which
proves only that the credentials are accepted (a search answers 200 without the permission
too — searches filter, they do not refuse). The permissions themselves are proven by the
e2e run (job activation for every type) and by `send-tickets.sh --probe-sla` (the
`sla.escalate` user-task update; the plain e2e completes user tasks as `admin`, so it does
not exercise them). An unauthorized activation may return an **empty batch instead of
403**, so an e2e run that stalls counts as an authorization failure; the fallback is
`tests/ops/create-worker-user.sh --wildcard` (resource id `*`, same three permissions),
to be recorded as observed behaviour and in the backlog.

Changing a password later, for any of the three users: `docs/runbooks/password-rotation.md`.

**Observed 2026-09-28:** user and authorization created, negative proof 403 / control 200,
both workers recreated as `worker` (`docker inspect` shows `CAMUNDA_USER=worker`), no auth
errors in the logs; e2e 8/8 plus dedup in 1:08 — the process-id scope is sufficient for job
activation of all seven types, the wildcard fallback was **not** needed; `--probe-sla`
passed as `worker` (priority 50 → 90, candidate group `supervisors`, `slaBreached = true`,
`sla_escalation` row written).

Phase 5 adds PostgreSQL (`postgres` service, profile `integrations`) for the LLM audit:
schema comes from `infra/postgres/init/` on the first start of an empty volume; the worker
needs `DATABASE_URL` in `infra/.env`, and **its password must match `POSTGRES_PASSWORD`**
in the same file. After the Phase 5 rename, one-time steps on the VM:

```bash
mv /opt/camunda-support-automation/workers/stub/.env \
   /opt/camunda-support-automation/workers/llm-classifier/.env
rm -rf /opt/camunda-support-automation/workers/stub    # rsync excludes keep it alive otherwise
docker compose up -d --build --remove-orphans          # without --remove-orphans the old
                                                       # worker-stub keeps polling the same job types
```

## Monitoring

Phase 6 adds the `monitoring` compose profile (Prometheus + Grafana on the stand VM,
ADR-008, `docs/design/operations-v1.md` §2). It is switched on permanently like the other
two profiles — `COMPOSE_PROFILES=integrations,workers,monitoring` in `infra/.env` — and
needs one new variable, `GRAFANA_ADMIN_PASSWORD` (Compose refuses to start Grafana without
it). The orchestration config gains the Prometheus endpoint on the management port, so the
first deploy restarts `orchestration`:

```bash
# on the VM, once: profile + Grafana password
sed -i "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=integrations,workers,monitoring|" .env
printf 'PROMETHEUS_VERSION=v3.15.0\nGRAFANA_VERSION=13.2.2\nGRAFANA_ADMIN_PASSWORD=%s\n' "$(openssl rand -base64 24)" >> .env
# from the workstation
make deploy
# on the VM: targets up, rules loaded, dashboard provisioned
tests/smoke/phase-6-monitoring.sh
```

What to look at:

- `http://<vm-host>:3000` — Grafana, user `admin` / `GRAFANA_ADMIN_PASSWORD`; folder
  "Camunda stand" holds the provisioned dashboard (read-only, `camunda-stand`).
  **Alerting → Alert rules** lists the two Prometheus rules (`CamundaIncidentsPending`,
  `OrchestrationTargetDown`) with their state.
- Prometheus is not published. Query it through Grafana → Explore, or on the VM with
  `docker compose exec prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=sum(zeebe_pending_incidents)'`.
- The scraped endpoint, through curl in the `elasticsearch` container (the orchestration image has no curl, same route as `tests/ops/_lib.sh`): `docker compose exec -T elasticsearch curl -sS http://orchestration:9600/actuator/prometheus | grep zeebe_pending_incidents`.

## Backups

Phase 6.4 turns on the three backup stores (`docs/design/operations-v1.md` §5, runbook
`docs/runbooks/backup-restore.md`): the Elasticsearch snapshot repository `camunda`
(`path.repo` on the `elasticsearch` service, registered by `tests/ops/backup.sh`), the
Zeebe `FILESYSTEM` backup store and the web-apps backup in `application.yaml`, and
`pg_dump` for PostgreSQL. All three write to `/srv/camunda-backups/{es,zeebe,pg}` on the
host (created in VM preparation). The deploy that introduces them restarts `orchestration`
and `elasticsearch`:

```bash
# from the workstation
make deploy
# on the VM, in infra/ — FIRST the writability checks (see Troubleshooting: a wrong owner
# on the Zeebe backup path leaves the partition without a leader while the container is
# "healthy"), THEN recreate the two services explicitly
../tests/smoke/phase-6-backup.sh          # the three "dir writable" lines must PASS
docker compose up -d --force-recreate orchestration elasticsearch
../tests/smoke/phase-6-backup.sh          # topology 200, backupRuntime answers a list, repository present
```

After **any** change to the backup keys, check that `GET :9600/actuator/backupRuntime`
answers a JSON list — the smoke does it. "healthy" in `docker compose ps` means the
management port answers, not that a partition has a leader.

## Before publishing

`make check-public` greps the repository for strings that must not appear in a public
repository and exits 0 only when nothing matches. The pattern comes from the owner's shell
environment (`PUBLIC_CHECK_PATTERN`, like `STAND_HOST`) and is never tracked. Run it
before every commit of docs or screenshots; the e2e README and the backlog reference it
as the closing step.

## Limitations (accepted for this stand)

- **Kafka runs without authentication or TLS** (PLAINTEXT on both listeners). Acceptable
  only inside the stand; the EXTERNAL listener (host port 9092) must stay within the lab
  network and never be exposed further.
- **`STAND_IP` is required for external Kafka access.** The EXTERNAL listener advertises
  `${STAND_IP}` from `infra/.env`; without the variable the stack still starts, but Kafka
  advertises `127.0.0.1` and clients outside the VM cannot connect. Set it to the VM's
  address before running anything Kafka-related from the workstation.
- **The FX gateway depends on the public frankfurter.app API** (ECB reference rates):
  outbound internet access is required, RSD is not supported, rates update once per day.
  Because the ECB rate moves daily, the D3-7 currency demo (ticket T-1007: 1050 USD →
  `priority = normal`) stays deterministic only while USD/EUR < 0.952 — comfortably within
  the historical range, but a fact to know when a distant-future run suddenly flips it to
  `high`.
- **No Alertmanager, no notification channel.** Alerts are evaluated by Prometheus and
  shown in Grafana (Alerting → Alert rules) and on the dashboard; nobody is paged. The
  stand has no mail relay or chat webhook, and the rule itself is the deliverable (ADR-008).
- **Backups stay on the VM's local disk** (Phase 6.4, ADR-008): they cover operator
  mistakes and the restore rehearsal, not the loss of the VM. Copying `/var/backups/camunda`
  off-host is an `rsync` line the backup runbook mentions and does not automate.
- **`make deploy` does not use `--wait`**: `docker compose up --wait` treats the
  successfully exited one-shot `kafka-init` container as a failure when no service depends
  on it (docker/compose#10596). Health gating relies on `depends_on` conditions; check
  `docker compose ps` after deploy instead.

## Troubleshooting

Symptom → cause → fix entries are added here the moment something breaks during installation.

- **Symptom:** `qm create` warns that the sum of thin volume sizes exceeds the thin pool.
  **Cause:** LVM-thin overprovisioning on the host; virtual sizes are counted, not actual usage.
  **Fix:** none required; keep `discard=on` on the disk and `fstrim.timer` enabled in the guest,
  and watch the pool's `Data%` on the host.
- **Symptom:** guides for Elasticsearch say to set `vm.max_map_count=262144`.
  **Cause:** Debian 13 already ships `vm.max_map_count=1048576` in
  `/usr/lib/sysctl.d/50-default.conf`; adding the classic override lowers it.
  **Fix:** do not override; verify with `sysctl vm.max_map_count`. Set `vm.swappiness=1` instead.
- **Symptom:** `systemctl enable qemu-guest-agent` prints "unit files have no installation config".
  **Cause:** static unit, started via udev when the virtio channel appears.
  **Fix:** none; check with `systemctl is-active qemu-guest-agent`.
- **Symptom:** `make sync` fails with `rsync: command not found` on the receiver.
  **Cause:** minimal Debian does not ship rsync.
  **Fix:** `apt-get install -y rsync` on the VM (included in VM preparation).
- **Symptom:** `make sync` fails with `mkdir "/opt/camunda-support-automation" failed: Permission denied`.
  **Cause:** `/opt` is root-owned and the sync user is unprivileged.
  **Fix:** as root: `mkdir -p /opt/camunda-support-automation && chown <user>: /opt/camunda-support-automation`.
- **Symptom:** `make sync` fails with rsync error 23 and hundreds of "Permission denied" on
  `workers/stub/.venv` and `__pycache__`.
  **Cause:** rsync `--delete` tries to remove the VM-side virtualenv, which doesn't exist on
  the workstation; the files were root-owned because the worker had been started as root.
  Without that accident the venv would have been silently deleted.
  **Fix:** Makefile excludes `.venv`, `__pycache__` and `*.pyc`; stand files owned by the
  deploy user (`chown`), worker runs as that user, never as root.
- **Symptom:** `docker compose ...` prints `no configuration file provided: not found`.
  **Cause:** Compose looks for the compose file in the current directory.
  **Fix:** run from `/opt/camunda-support-automation/infra`, or export `COMPOSE_FILE` (see Sync setup).
- **Symptom:** Elasticsearch health is `yellow` right after the first start.
  **Cause:** single node, indices created with one replica; replica shards stay unassigned.
  **Fix:** `camunda.data.secondary-storage.elasticsearch.number-of-replicas: 0` in the
  orchestration config; on an empty stand recreate the volumes (`docker compose down -v`).
- **Symptom:** host log timestamps differ from Operate and container logs by the local UTC offset.
  **Cause:** the VM keeps the installer's local time zone while everything in the stack logs in UTC.
  **Fix:** `timedatectl set-timezone UTC` on the VM.
- **Symptom:** a ticket with `needsReview = true` took the `intent = "question"` flow at the
  single `gw-intent` gateway (process v2), although the needsReview flow was defined first in
  the XML.
  **Cause:** not investigated; branch selection depended on gateway condition order.
  **Fix:** separate `gw-needs-review` gateway before `gw-intent` with mutually exclusive
  conditions (design D2-7), deployed as v3.
- **Symptom:** process-instance search filtered by a variable returns 0 items although the
  instance is visible in Operate.
  **Cause:** v2 variable filters compare JSON-encoded values; a string must be sent with
  embedded quotes (`"\"T-1001\""`), a bare `"T-1001"` never matches.
  **Fix:** JSON-encode the filter value (in jq: `value: ($id | tojson)`), as in
  `tests/e2e/send-tickets.sh`.
- **Symptom:** output mapping never resolves; the BPMN XML contains
  `zeebe:output source="==routing.team"`.
  **Cause:** the Modeler mapping field is already in FEEL mode (the `=` badge), and the
  expression was typed with a leading `=` as well — the doubled prefix ends up in the XML.
  **Fix:** type mapping expressions without `=`; check with `grep -n 'source="=='
  processes/*.bpmn` (must be empty).
- **Symptom:** any compose command on the VM (even `docker compose stop worker-booking`)
  fails with `no such service: booking-api`.
  **Cause:** the `workers` services `depends_on` `booking-api` from the `integrations`
  profile; with no profile active, compose cannot resolve the dependency.
  **Fix:** `COMPOSE_PROFILES=integrations,workers` in `infra/.env` (in `.env.example` since
  Phase 4.2) — profiles are then active for every compose command without `--profile` flags.
- **Symptom:** connectors logs show `NOT_COORDINATOR` / group-coordinator warnings right
  after (re)start of the Kafka inbound connector.
  **Cause:** the consumer group's coordinator is still being elected on the single broker
  during the first join; the client retries by design.
  **Fix:** none — expected noise, gone within seconds. Investigate only if it repeats
  continuously.
- **Symptom:** variables returned by a job worker are not visible in the process scope; the
  next REST connector fails with `url: null` and an incident "No retries left".
  **Cause:** the service task carries an output mapping (the v1 `resolution` literal), and
  any output mapping makes **all** completion variables task-local.
  **Fix:** map the worker's variables out explicitly on that task (v6, D4-6 in
  `docs/design/integrations-v1.md`) — e.g. `=refundCurrency` → `refundCurrency`.
- **Symptom:** the classifier fails at the first LLM call with
  `TypeError: Messages.create() got an unexpected keyword argument 'temperature'`.
  **Cause:** `anthropic==1.8.0` removed sampling parameters (`temperature`, `top_p`,
  `top_k`) from `messages.create` for current models; the argument no longer exists —
  it did not move or get renamed.
  **Fix:** call `messages.create` without `temperature`; determinism relies on the prompt
  contract + JSON-schema validation + one retry (D5-2, `docs/design/llm-classifier-v1.md`).
- **Symptom:** every classify call fails with `400 invalid_request_error:
  "output_config.format.schema: For 'number' type, properties maximum, minimum are not
  supported"`.
  **Cause:** structured output (`output_config.format`) rejects numerical constraints
  (`minimum`/`maximum`/`multipleOf`), string constraints (`minLength`/`maxLength`) and
  `pattern` in the wire schema.
  **Fix:** two schemas — `API_SCHEMA` (stripped copy) goes to the API, the full `SCHEMA`
  stays as the local jsonschema validation, which still enforces the confidence range
  and rationale length (`workers/llm-classifier/llm/guardrails.py`, D5-2).
- **Symptom:** a review correction is ignored — after completing `review-classification`
  with a different `intent`, the instance still routes by the LLM's original intent
  (e2e: T-1004 corrected to `question` but ends in `handle-by-agent`).
  **Cause:** D4-6 on the user task — its v6 output mapping (`needsReview=false`) makes
  all completion variables task-local, so the form's `intent` never reaches the process
  scope.
  **Fix:** process v7 (Phase 5.3): explicit output mappings for
  `intent`/`sentiment`/`escalate`/`reviewedBy` on `review-classification`, together with
  the D5-4 re-routing (`docs/design/process-v1.md` §11). Rule of thumb: a task with any
  output mapping must map out *every* completion variable it wants in the process scope.
- **Symptom:** an instance loops on a service task with no incident — Operate shows it
  green with the token on `cancel-refund` (or `change-booking`), and `worker-booking`
  logs the same pair every 60 s (the job timeout): `msg=error … errorCode=BOOKING_NOT_FOUND`
  followed by `msg="job lifecycle call failed" error="POST /v2/jobs/<key>/errors: HTTP 404 …
  No static resource v2/jobs/<key>/errors"`. Seen on the first 5.5 run (`20260925T141107Z`,
  T-1008 with an unknown `bookingRef`).
  **Cause:** two defects. The throw-error call used `/v2/jobs/{key}/errors`; the 8.9
  Orchestration Cluster REST API path is `/v2/jobs/{jobKey}/error` (singular; failure and
  completion are `/failure` and `/completion`). And the worker only logged a failed
  lifecycle call, so the job timed out, was re-activated and failed identically forever —
  nothing ever reached the engine.
  **Fix:** `workers/booking/camunda.go` uses the singular path, and `report()` in
  `main.go` turns a failed error/completion call into `POST /failure` with `retries: 0`
  and the original message, so the engine raises an incident that names the problem
  instead of a silent loop. With the fix an unknown `bookingRef` now surfaces as an
  **incident on `cancel-refund`** — `BOOKING_NOT_FOUND` is thrown correctly, but the model
  has no error boundary event to catch it yet. That is the input to the Phase 6
  error-boundary scenario B; reproduce with `tests/e2e/send-tickets.sh --probe-unknown-booking`.
  Screenshots: `../assets/phase-5/silent-loop-before-fix.png` (before),
  `../assets/phase-5/incident-booking-not-found.png` (after, probe run 2026-09-25).
- **Symptom:** a configuration backup made next to the environment file, such as
  `infra/.env.bak`, is gone after the next `make deploy` (seen in Phase 6.1 while
  restoring `DATABASE_URL` for scenario A3a).
  **Cause:** `make sync` runs rsync with `--delete`, and its exclude list matched only the
  exact name `.env`; every other file that is not in the repository is removed from the
  stand on each deploy.
  **Fix:** keep configuration backups **outside the deploy directory**, in a root-owned
  directory on the host, e.g. `/root/env-backups/` (as root: `cp infra/.env
  /root/env-backups/env.$(date +%Y%m%dT%H%M%S)`). As a safety net the Makefile now also
  excludes `.env.bak*` from the sync (dry run verified: `.env.example` is still
  transferred, `.env` and `.env.bak*` are left alone) — but a backup that lives next to the
  file it backs up is still on the wrong disk; the exclude only prevents the accident.
- **Symptom:** after enabling the Zeebe `FILESYSTEM` backup store, the `orchestration`
  container is `healthy`, but the REST API answers "partition 1 is currently INACTIVE with
  no leader" and nothing is processed; the log shows
  `AccessDeniedException: /usr/local/camunda/backup/contents` and
  `Failed to install partition 1`. Seen 2026-09-27; the stand was leaderless for about
  70 minutes before the cause was found.
  **Cause:** the bind-mounted backup path was owned by uid 1000, but the `camunda/camunda`
  image runs as uid **1001**; the broker could not create the store's directory and refused
  to install the partition. The healthcheck only probes the management port.
  **Fix:** `chown 1001:1001 /srv/camunda-backups/zeebe` (root), then
  `docker compose up -d --force-recreate orchestration`. Rule: run the writability checks
  of `tests/smoke/phase-6-backup.sh` **before** recreating with new backup keys, and treat
  `GET :9600/actuator/backupRuntime` answering a list as the proof that the store works.
- **Symptom:** `tests/ops/restore.sh` fails in the snapshot step with `jq: error Cannot
  iterate over null`; `GET /_snapshot/camunda/_all` is 404 on the freshly started
  Elasticsearch.
  **Cause:** the snapshot repository is cluster state stored in the `elastic` volume, which
  the restore removes on purpose; the files under `/srv/camunda-backups/es` are intact, the
  registration is gone.
  **Fix:** `restore.sh` re-registers and verifies the repository right after the clean start
  (`ensure_repo` in `tests/ops/_lib.sh`) and lists the set's snapshots from the repository,
  not from `backupHistory` (the cluster is stopped at that point). Seen on the first
  rehearsal 2026-09-27.
- **Symptom:** the orchestration log says the backup repository key is legacy.
  **Cause:** the 8.9 backups concept page still names `camunda.data.backup.repository-name`;
  the current key is `camunda.data.secondary-storage.elasticsearch.backup.repository-name`.
  **Fix:** the new key in `application.yaml` (the legacy one keeps working, with the warning).
  The Zeebe keys `camunda.data.primary-storage.backup.*` work as documented.
- **Symptom:** the API still answers 200 without credentials after enabling protection.
  **Cause:** the config was edited on the workstation but not synced to the VM; Compose
  restarted the old files.
  **Fix:** `make sync` before every restart; verify with `grep unprotected` on the VM.
  Use `curl -sS`, not `curl -s`, in checks so failures are visible.
- **Symptom:** login with `demo` / `demo` fails.
  **Cause:** the demo user is removed; users are bootstrapped from `camunda.security.initialization`
  and only on a fresh secondary storage.
  **Fix:** log in as `admin` with the password from `infra/.env`. To change users after the first
  start, recreate the volumes (`docker compose down -v`) or use the Admin UI at `/admin`.
- **Symptom:** `make check-public` fails on a screenshot, e.g. `Binary file ./docs/assets/phase-6/a2-01-outage-log.png matches`.
  **Cause:** `grep -i` scans PNG bytes; three random compressed bytes can spell a pattern word in mixed case (seen in Phase 6.1 on two PNGs).
  **Fix:** the check runs with `-I` (skip binary files). Screenshots are checked visually when cropped — no address bar, no hostnames, no internal IPs.
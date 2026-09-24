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
still unset — that is intentional (`${VAR:?message}` in the compose file).

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
(`worker-booking`, `worker-stub`), built on the VM by `make deploy`. The `workers` profile
**cannot start on its own**: its services `depends_on` `booking-api` from the
`integrations` profile. Both profiles are activated permanently via
`COMPOSE_PROFILES=integrations,workers` in `infra/.env` (see `.env.example`), so a plain
`docker compose up -d --build` — and every other compose command — sees all services:

```bash
docker compose up -d --build
```

The venv run of the stub worker (`workers/stub/README.md`) remains available as a dev
fallback — never run it and the `worker-stub` container at the same time, they compete for
the same job types.

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
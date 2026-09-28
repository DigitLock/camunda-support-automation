# Runbook: password rotation

**Scope:** changing the password of one of the three Orchestration Cluster users on the
running stand — `worker` (both job workers), `admin` (operator, scripts, web logins) and
`connectors` (the Connectors runtime) — without losing jobs. Design:
`docs/design/operations-v1.md` §7. Related: `docs/ops/install.md` "Worker user",
`docs/runbooks/backup-restore.md` §6 (a restore brings passwords back as of the backup).

**Status:** rehearsed for `worker` (see *Last run* at the end); documented, not run, for
`admin` and `connectors`.

Rules that hold for all three: generate with `openssl rand -hex 24` (hex, nothing to escape
in `sed` or JSON), keep the value in a shell variable, never `echo` it, and send run logs to
`/tmp/phase-6-raw/`. The change is `PUT /v2/users/{username}` with `{"password": …}` as
`admin` (8.9 REST API, `updateUser`), then the new value goes wherever the old one was read
from — the table below — and the consuming containers are recreated.

## 1. Where each password is read

| User | Read by | Where the value lives |
|---|---|---|
| `worker` | `worker-booking`, `worker-llm-classifier` (`environment` in `infra/docker-compose.yml`) | `CAMUNDA_WORKER_PASSWORD` in `infra/.env` — the only place |
| `admin` | `tests/ops/_lib.sh` and every `tests/ops/*.sh`, `tests/smoke/phase-6-backup.sh`, `tests/ops/upgrade-lab.sh` (its own `upgrade-lab/.env.lab`), the e2e shell environment (`CAMUNDA_USER`/`CAMUNDA_PASSWORD`), Operate / Tasklist / Admin UI logins, and `orchestration`'s environment (`CAMUNDA_ADMIN_PASSWORD`, read only by `camunda.security.initialization` on a fresh secondary storage) | `CAMUNDA_ADMIN_PASSWORD` in `infra/.env`, `upgrade-lab/.env.lab`, the operator's shell |
| `connectors` | the `connectors` service (`CAMUNDA_CLIENT_AUTH_PASSWORD`), `orchestration`'s environment (initialization only) | `CAMUNDA_CONNECTORS_PASSWORD` in `infra/.env`, `upgrade-lab/.env.lab` |

## 2. `worker` — rehearsed

Order: **stop both workers → change the password → update `.env` → start**. Stopping first
means no worker ever holds a password the cluster no longer accepts, so the window in §2.1
is a "workers down" window, not a "wrong password" window.

```bash
cd /opt/camunda-support-automation/infra
tests/e2e/send-tickets.sh --incidents        # from the workstation: no ACTIVE incidents, nothing in flight that matters

# 1. stop — SIGTERM, see §2.1 for what each worker does with in-flight jobs.
#    Read the stop logs NOW: step 4 recreates the containers and their logs are gone with them.
docker compose stop worker-booking worker-llm-classifier
docker compose logs --since 3m worker-booking worker-llm-classifier | grep -Ei 'shutdown|worker stopped' | tee /tmp/phase-6-raw/rotation-stop.txt

# 2. new password, kept in the shell only
NEW=$(openssl rand -hex 24)
. ./.env
curl -sS -o /dev/null -w '%{http_code}\n' -u "admin:$CAMUNDA_ADMIN_PASSWORD" \
  -X PUT http://localhost:8080/v2/users/worker -H 'Content-Type: application/json' \
  -d "$(jq -cn --arg p "$NEW" '{password: $p, name: "Worker", email: "worker@example.com"}')"   # 200

# 3. .env, then the key check still prints nothing
sed -i "s|^CAMUNDA_WORKER_PASSWORD=.*|CAMUNDA_WORKER_PASSWORD=$NEW|" .env
comm -23 <(grep -o '^[A-Z_]*=' .env.example | sort) <(grep -o '^[A-Z_]*=' .env | sort)

# 4. start — the env changed, so Compose recreates both containers
docker compose up -d worker-booking worker-llm-classifier
unset NEW

# 5. verify: credentials accepted with the new value, no auth errors, jobs flowing
tests/ops/create-worker-user.sh --verify
docker compose logs --since 2m worker-booking worker-llm-classifier | grep -Ei '401|403|unauthori' || echo "no auth errors"
```

Then from the workstation: `tests/e2e/send-tickets.sh && tests/e2e/send-tickets.sh --check`
(8/8) — every job type activated with the new password.

### 2.1 The window, and what happens to jobs in it

The window runs from step 1 to step 4: seconds when the commands are pasted as a block,
plus the drain in step 1. During it no worker polls, so jobs that the engine creates wait
as CREATED and are activated as soon as the workers are back — nothing is lost and nothing
is retried. What SIGTERM does with jobs that are **in flight** at step 1 (from the code):

- `worker-booking` handles SIGTERM: it stops activating and waits up to 25 s
  (`drainTimeout`, `workers/booking/main.go`) for in-flight jobs to finish, under Compose's
  30 s `stop_grace_period`; it logs `shutdown: activation stopped, waiting for in-flight
  jobs` and then `shutdown complete`, or `drain timeout reached, exiting with jobs in
  flight`. A job that finishes inside the drain is completed with the old password, which is
  still valid at that point — that is why the password changes after the stop.
- `worker-llm-classifier` handles SIGTERM by cancelling the SDK's `run_workers()`
  (`workers/llm-classifier/worker.py`). Observed: the SDK logs `Worker stopped` five times,
  one per job type, and the container is down 0.5 s later; the worker's own
  `shutdown: workers stopped` line does not appear (the cancellation ends the process
  before it is written). The pollers stop cleanly, but a handler that is mid-call (an LLM
  request) is cancelled with them, not drained — from the code, not observed: nothing was in
  flight during the rehearsal. Its job stays ACTIVATED until the job timeout (30 s, 90 s for
  `ticket.answer` / `ticket.notify`), is then activated again by the restarted worker and
  runs once more — the LLM call is repeated (`docs/backlog.md`, "classifier calls the LLM
  before the audit write"). No job is lost; one may be billed twice.

So: booking drains, the classifier releases. Rotate when `--incidents` shows a quiet stand
and no ticket was just sent, and the window costs nothing. Rehearsed window: 13 s from
`stop` to `up -d` with the commands pasted one by one.

Zero-window pattern for a production cluster: create a second technical user with the same
authorization (`create-worker-user.sh` with a different username), switch the workers to
it, verify, then delete the old user — the old password stays valid until the switch is
proven, and nothing is stopped.

## 3. `admin` — documented, not run

Consumers are in §1; the change itself is one call, the fan-out is the work.

1. `PUT /v2/users/admin` with the new password, authenticated as `admin` with the **old**
   one (the call that changes it is the last one made with the old value).
2. `sed` the new value into `infra/.env` (`CAMUNDA_ADMIN_PASSWORD`) and
   `infra/upgrade-lab/.env.lab`; export it in the operator's shell for the e2e and the
   runbooks; the web logins use it from now on.
3. `orchestration` carries `CAMUNDA_ADMIN_PASSWORD` in its environment, so the next
   `docker compose up -d` (or `make deploy`) **recreates the cluster container** — a
   restart of the Orchestration Cluster. The value is read only by
   `camunda.security.initialization` on a fresh secondary storage, so it is not urgent for
   the running cluster; do the recreate in the next maintenance window, but do update
   `.env` immediately: `restore.sh`'s seed start and a `down -v` read it.
4. Verify: `tests/ops/verify-state.sh` (uses `admin` via `_lib.sh`) answers; log in to
   Operate.

Nothing stops during an `admin` rotation: no worker uses it. The window is the operator's
own: a script started with the old value fails with 401 until the shell is updated.

## 4. `connectors` — documented, not run

1. `PUT /v2/users/connectors` with the new password, as `admin`.
2. `sed` the new value into `infra/.env` (`CAMUNDA_CONNECTORS_PASSWORD`) and
   `infra/upgrade-lab/.env.lab`.
3. `docker compose up -d connectors` — recreated with the new value. `orchestration` has
   the same caveat as for `admin` (environment changed, recreated on the next `up -d`;
   initialization only).
4. Verify: `docker compose logs --since 2m connectors` shows no 401; send one e2e ticket
   (`send-tickets.sh`), which enters through the Kafka inbound connector and leaves through
   the REST and Kafka outbound connectors.

Window: between step 1 and step 3 the runtime polls with the old password and gets 401 —
the inbound Kafka connector does not consume (the message waits in the topic, Kafka keeps
it) and the outbound connector jobs wait as CREATED. Same shape as §2.1, on the connectors
side; not observed on this stand.

## 5. Failure modes

| What you see | Cause | Action |
|---|---|---|
| a worker logs 401 after the rotation | `.env` updated but the container not recreated, or the reverse | `docker inspect <container> --format '{{.Config.Env}}'` shows which value it runs with; `docker compose up -d <service>` |
| `PUT /v2/users/…` answers 403 | not authenticated as `admin` (only `admin` has `USER`/`UPDATE`) | use the admin credentials from `infra/.env` |
| `PUT` answers 404 | the user does not exist on this storage (restored from an older backup, §6) | `tests/ops/create-worker-user.sh` recreates `worker` with the current `.env` value |
| the key check prints `CAMUNDA_WORKER_PASSWORD` | the `sed` did not match | `grep -c '^CAMUNDA_WORKER_PASSWORD=' .env`, append the line if missing |

## 6. Restore interplay

A restore brings users **and their passwords** back as of the backup (`backup-restore.md`
§6). After restoring a backup taken before a rotation, either rerun the rotation (§2) or
put the matching older `.env` back; after restoring a backup taken before 6.5, `worker`
does not exist — rerun `create-worker-user.sh`. Not tested.

## Last run

**2026-09-28, `worker`, 8.9.21.** `make sync`, `--incidents` empty. `stop` at 11:32:04Z,
`up -d` (both recreated) at 11:32:17Z — workers-down window 13 s. `worker-booking` on
SIGTERM: `shutdown: activation stopped, waiting for in-flight jobs` (limit 25 s) then
`shutdown complete` at once, nothing in flight; `stop_grace_period` 30 s confirmed on both
services. `worker-llm-classifier`: five `Worker stopped` lines, stop in 0.5 s, no
`shutdown` line of its own — read in a separate stop/start at 12:03:23Z, because the `up -d`
of the rehearsal had recreated the container and dropped the logs of the first stop (hence
the `tee` in step 1). `PUT /v2/users/worker` → 200; `.env` updated, key check empty;
`create-worker-user.sh --verify`: negative 403, control 200, credentials accepted 200; both
workers healthy, no auth errors. First e2e afterwards 6/8 — the script's own user-task
completion race (`tests/e2e/send-tickets.sh`, a 404 on a second completion of the same task;
it runs as `admin`, no worker involved, not a rotation effect); T-1005 and T-1006 cancelled in
Operate, rerun 8/8 plus dedup in 1:08.

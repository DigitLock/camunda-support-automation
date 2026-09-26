# E2E test: support-request-v1

`send-tickets.sh` drives the eight tickets of `tickets.json` (the §8 set of
`docs/design/process-v1.md` plus T-1006/T-1007 from Phases 3–4 and the Russian refund
ticket T-1008 from Phase 5.5) through the deployed process (bash + curl + jq). Ticket
payloads and expectations live in `tickets.json`; the script contains no data.

Prerequisites: core stack up, `support-request-v1` (v5+) deployed, worker containers
running (compose profile `workers`, see `docs/ops/install.md`). Since process v5 the
tickets are **produced to Kafka** (`support.ticket.created`) — the Kafka start event
connector is the only process entry — and verification still runs over the REST API:

```bash
# verification (same as the workers); since 5.4 --check also asserts the LLM message
# variables (customerMessage in the ticket language, answerText/answerKbIds on T-1003,
# the refund amount inside the refund messages of T-1002/T-1008, and a Cyrillic-ratio
# sanity check: > 0.5 of the letters for ru, < 0.1 for en)
# before publishing anything from this repo: `make check-public` (exit 0 = clean; the
# pattern comes from the owner's shell environment, PUBLIC_CHECK_PATTERN)
export CAMUNDA_BASE_URL=http://localhost:8080   # or the stand's address
export CAMUNDA_USER=admin
export CAMUNDA_PASSWORD=...                     # from infra/.env on the stand

# producing: kcat (brew install kcat) against the stand's EXTERNAL Kafka listener
export STAND_IP=...                             # VM address; or KAFKA_BROKER=host:9092
# without kcat the script falls back to kafka-console-producer over SSH (needs STAND_HOST)
export STAND_HOST=camunda-stand                 # --check queries classification_review over SSH (5.3)
```

## Modes

```bash
# regression run, no interaction: publish 5 messages, complete the two user tasks via REST,
# verify paths + resolution + notificationTemplate, exit 0/1
./send-tickets.sh

# acceptance run: --manual-user-tasks only publishes, then lists EVERY open user task of
# the run (element id, ticketId, userTaskKey) — the expected ones (T-1004, T-1005) plus any
# borderline ticket the classifier sent to review (T-1006 on most runs). Instances that
# finish without a user task or get stuck (incident) are printed as "no user task,
# state=…" after at most TIMEOUT_SECONDS. It verifies nothing; complete the tasks in
# Tasklist, then run the verification as a separate step:
./send-tickets.sh --manual-user-tasks
./send-tickets.sh --check

# negative probe (never part of the default run): one cancel ticket with an unknown
# bookingRef → BOOKING_NOT_FOUND → incident on cancel-refund (no boundary event yet, Phase 6.2)
./send-tickets.sh --probe-unknown-booking

# Phase 6.1 incident probes (own probe-… run id, never part of verify): each produces its
# ticket(s), prints "ticketId processInstanceKey" once the instance exists, and exits —
# the incident is watched with --incidents, Grafana or Operate
./send-tickets.sh --probe-booking-5xx    # A1: BK-FAIL-500 → 500 → retries with backoff → incident
make fault-on && ./send-tickets.sh --probe-outage   # A2: injected 503 on BK-81 (cancel) + BK-77 (change)
./send-tickets.sh --probe-classify       # A3b: with postgres stopped → audit write fails → incident

# operator view: ACTIVE incidents, then CREATED jobs older than 60 s that no worker ever
# activated (deadline null) — the "worker is down" signal without monitoring (A3a)
./send-tickets.sh --incidents
```

Each run gets a `RUN_ID` (UTC timestamp). The event payload carries
`messageId = <ticketId>-<RUN_ID>` — the dedup key of the Kafka start event connector
(D4-5), so repeated runs start fresh instances — and `runId`, so verification finds
exactly this run's instances. The Kafka record key is the `ticketId`. The last `RUN_ID`
is stored in `.last-run` (git-ignored) for `--check`.

## What verification checks per ticket

- the process instance created for `(runId, ticketId)` is `COMPLETED`;
- the set of completed element IDs equals the expected path from §8 (set equality — order
  and repeated gateway visits are not asserted);
- `resolution` and `notificationTemplate` match §8 (`notify-<resolution>`);
- routing (`team`, `priority`, `slaHours`, `requiredChecks` as a set) and a non-empty
  `slaDeadline`;
- FX variables: `bookingValueEur > 0` where the ticket has a `bookingValue` (absent
  otherwise), `refundAmountCustomer > 0` on the cancel branch;
- idempotency: every publish run re-sends T-1001 with the same `messageId`; verification
  asserts exactly one instance per `(runId, ticketId)` and prints
  `PASS dedup: duplicate messageId for T-1001 ignored`;
- `--check` additionally consumes `support.ticket.resolved` (kcat required — skipped with
  a WARN otherwise) and matches this run's events: one per ticket, `resolution` as
  expected, `refundAmountCustomer > 0` on the cancel branch.

One `PASS`/`FAIL` line per ticket; exit code is non-zero if anything failed.

## Example run

Verification output of run `20260923T210154Z` (six tickets, process v4 with DMN routing —
identical closing step for the unattended and manual modes):

```
run 20260923T210154Z: verifying
PASS T-1001: path ok, resolution=booking_changed, routing ok, slaDeadline=2026-09-24T21:01:54.413Z[GMT]
PASS T-1002: path ok, resolution=refund_issued, routing ok, slaDeadline=2026-09-24T21:01:55.54Z[GMT]
PASS T-1003: path ok, resolution=answered, routing ok, slaDeadline=2026-09-24T21:01:55.549Z[GMT]
PASS T-1004: path ok, resolution=answered, routing ok, slaDeadline=2026-09-24T21:01:55.512Z[GMT]
PASS T-1005: path ok, resolution=agent_handled, routing ok, slaDeadline=2026-09-24T01:01:55.526Z[GMT]
PASS T-1006: path ok, resolution=answered, routing ok, slaDeadline=2026-09-24T01:01:55.561Z[GMT]
all tickets passed
```

Note the deadlines: T-1005 and T-1006 are `priority = high`, so their `slaDeadline` is
4 hours after the run; the other four get 24 hours.

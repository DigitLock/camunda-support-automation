# E2E test: support-request-v1

`send-tickets.sh` drives the five §8 tickets from `docs/design/process-v1.md` through the
deployed process over the REST API v2 (bash + curl + jq). Ticket payloads and expectations live
in `tickets.json`; the script contains no data.

Prerequisites: core stack up, `support-request-v1` deployed, worker containers running
(compose profile `workers`, see `docs/ops/install.md`). Environment contract is the same
as the workers:

```bash
export CAMUNDA_BASE_URL=http://localhost:8080   # or the stand's address
export CAMUNDA_USER=admin
export CAMUNDA_PASSWORD=...                     # from infra/.env on the stand
```

## Modes

```bash
# regression run, no interaction: publish 5 messages, complete the two user tasks via REST,
# verify paths + resolution + notificationTemplate, exit 0/1
./send-tickets.sh

# acceptance run: --manual-user-tasks only publishes, waits for tickets 4 and 5 to reach
# their user task, prints the task keys and exits — it verifies nothing. Complete both
# tasks in Tasklist, then run the verification as a separate step:
./send-tickets.sh --manual-user-tasks
./send-tickets.sh --check
```

Each run gets a `RUN_ID` (UTC timestamp). It is sent as `messageId = <ticketId>-<RUN_ID>`
(so repeated runs pass the message uniqueness check) and as the `runId` process variable
(so verification finds exactly this run's instances). The last `RUN_ID` is stored in
`.last-run` (git-ignored) for `--check`.

## What verification checks per ticket

- the process instance created for `(runId, ticketId)` is `COMPLETED`;
- the set of completed element IDs equals the expected path from §8 (set equality — order
  and repeated gateway visits are not asserted);
- `resolution` and `notificationTemplate` match §8 (`notify-<resolution>`).

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

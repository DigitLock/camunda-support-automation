# E2E test: support-request-v1

`send-tickets.sh` drives the five §8 tickets from `docs/design/process-v1.md` through the
deployed process over the REST API v2 (bash + curl + jq). Ticket payloads and expectations live
in `tickets.json`; the script contains no data.

Prerequisites: core stack up, `support-request-v1` deployed, stub worker running
(`workers/stub/`). Environment contract is the same as the stub worker:

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

# acceptance run: publish, wait for tickets 4 and 5 to reach their user task, print the
# task keys and exit; complete both in Tasklist, then verify:
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

Unattended run:

```
run 20260922T212313Z: publishing ticket.created for 5 tickets
published T-1001 … T-1005 (messageId <ticketId>-20260922T212313Z)
completed user task review-classification for T-1004
completed user task handle-by-agent for T-1005
run 20260922T212313Z: verifying
PASS T-1001: path ok, resolution=booking_changed, notificationTemplate=notify-booking_changed
PASS T-1002: path ok, resolution=refund_issued, notificationTemplate=notify-refund_issued
PASS T-1003: path ok, resolution=answered, notificationTemplate=notify-answered
PASS T-1004: path ok, resolution=answered, notificationTemplate=notify-answered
PASS T-1005: path ok, resolution=agent_handled, notificationTemplate=notify-agent_handled
all tickets passed
```

Manual run:

```
$ tests/e2e/send-tickets.sh --manual-user-tasks
run 20260922T212555Z: publishing ticket.created for 5 tickets
T-1004 waits at review-classification — userTaskKey 2251799813709378
T-1005 waits at handle-by-agent — userTaskKey 2251799813709400
complete both in Tasklist, then run: send-tickets.sh --check
$ tests/e2e/send-tickets.sh --check
run 20260922T212555Z: verifying
PASS T-1001 … PASS T-1005 (same five lines as above)
all tickets passed
```

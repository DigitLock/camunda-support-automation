#!/usr/bin/env bash
# E2E test for support-request-v1 (design §8). Produces the tickets from tickets.json to
# the Kafka topic support.ticket.created (kcat, or a kafka-console-producer fallback over
# SSH), completes user tasks over REST (or leaves them for Tasklist with
# --manual-user-tasks), then verifies path, resolution, routing and FX variables per ticket.
#
# Producing needs either kcat + KAFKA_BROKER (or STAND_IP, port 9092), or STAND_HOST for
# the SSH fallback. Verification uses the REST API as before (CAMUNDA_* variables).
#
# Modes:
#   send-tickets.sh                     unattended run: publish, complete user tasks, verify
#   send-tickets.sh --manual-user-tasks publish, print user task keys for Tasklist, exit
#   send-tickets.sh --check             verify the most recent run (reads .last-run)
#
# Env contract (same as workers/stub): CAMUNDA_BASE_URL, CAMUNDA_USER, CAMUNDA_PASSWORD.
set -euo pipefail

cd "$(dirname "$0")"
TICKETS_FILE=tickets.json
LAST_RUN_FILE=.last-run
PROCESS_ID=support-request-v1
TOPIC=support.ticket.created
RESOLVED_TOPIC=support.ticket.resolved
TIMEOUT_SECONDS=60
POLL_INTERVAL=2

for var in CAMUNDA_BASE_URL CAMUNDA_USER CAMUNDA_PASSWORD; do
  if [ -z "${!var:-}" ]; then
    echo "error: $var is not set (same contract as workers/stub, see its .env.example)" >&2
    exit 1
  fi
done

BASE="${CAMUNDA_BASE_URL%/}/v2"

api() { # api METHOD PATH [JSON_BODY]
  local method=$1 path=$2 body=${3:-}
  if [ -n "$body" ]; then
    curl -sS --fail-with-body -u "$CAMUNDA_USER:$CAMUNDA_PASSWORD" \
      -X "$method" "$BASE$path" -H 'Content-Type: application/json' -d "$body"
  else
    curl -sS --fail-with-body -u "$CAMUNDA_USER:$CAMUNDA_PASSWORD" -X "$method" "$BASE$path"
  fi
}

# poll EXPR_CMD... — repeats the command until it prints non-empty output or the timeout hits.
poll() {
  local deadline=$((SECONDS + TIMEOUT_SECONDS)) out
  while [ "$SECONDS" -lt "$deadline" ]; do
    out=$("$@" || true)
    if [ -n "$out" ]; then echo "$out"; return 0; fi
    sleep "$POLL_INTERVAL"
  done
  return 1
}

ticket_ids() { jq -r '.[].ticketId' "$TICKETS_FILE"; }
ticket() { jq -c --arg id "$1" '.[] | select(.ticketId == $id)' "$TICKETS_FILE"; }

# messageId in the payload is the dedup key of the Kafka start event connector (D4-5)
ticket_payload() {
  ticket "$1" | jq -c --arg run "$RUN_ID" \
    'del(.expected) + {runId: $run, messageId: (.ticketId + "-" + $run)}'
}

produce_event() { # produce_event KEY JSON_PAYLOAD
  local key=$1 payload=$2 broker="${KAFKA_BROKER:-${STAND_IP:-}:9092}"
  if command -v kcat >/dev/null 2>&1; then
    if [ "$broker" = ":9092" ]; then
      echo "error: set KAFKA_BROKER (or STAND_IP) to reach Kafka with kcat" >&2
      exit 1
    fi
    printf '%s\n' "$payload" | kcat -b "$broker" -t "$TOPIC" -k "$key" -P
  else
    # fallback: produce from inside the kafka container over SSH
    if [ -z "${STAND_HOST:-}" ]; then
      echo "error: kcat not found and STAND_HOST is not set for the SSH fallback" >&2
      exit 1
    fi
    printf '%s\t%s\n' "$key" "$payload" | ssh "$STAND_HOST" \
      "cd /opt/camunda-support-automation/infra && docker compose exec -T kafka \
       /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:29092 \
       --topic $TOPIC --property parse.key=true --property 'key.separator=\t' > /dev/null"
  fi
}

publish_tickets() {
  RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
  echo "run $RUN_ID: producing to ${TOPIC} for $(ticket_ids | wc -l | tr -d ' ') tickets"
  local id
  for id in $(ticket_ids); do
    produce_event "$id" "$(ticket_payload "$id")"
    echo "produced $id (messageId $id-$RUN_ID)"
  done
  # idempotency probe: the same messageId again — the connector must drop it (D4-5);
  # verify() then asserts exactly one instance per (runId, ticketId)
  produce_event "T-1001" "$(ticket_payload "T-1001")"
  echo "produced duplicate T-1001 (same messageId, expecting dedup)"
  echo "$RUN_ID" > "$LAST_RUN_FILE"
}

# v2 variable filters compare JSON-encoded values: "T-1001" must be sent as "\"T-1001\""
instance_key() {
  api POST /process-instances/search "$(jq -cn --arg pid "$PROCESS_ID" --arg run "$RUN_ID" --arg id "$1" \
    '{filter: {processDefinitionId: $pid, variables: [{name:"runId",value:($run|tojson)},{name:"ticketId",value:($id|tojson)}]}}')" \
    | jq -r '.items[0].processInstanceKey // empty'
}

# instance_count TICKET_ID — how many instances exist for (runId, ticketId); dedup check
instance_count() {
  api POST /process-instances/search "$(jq -cn --arg pid "$PROCESS_ID" --arg run "$RUN_ID" --arg id "$1" \
    '{filter: {processDefinitionId: $pid, variables: [{name:"runId",value:($run|tojson)},{name:"ticketId",value:($id|tojson)}]}}')" \
    | jq -r '.items | length'
}

# open_user_task INSTANCE_KEY -> "userTaskKey elementId" once a CREATED task exists
open_user_task() {
  api POST /user-tasks/search "$(jq -cn --arg k "$1" '{filter: {processInstanceKey: $k, state: "CREATED"}}')" \
    | jq -r '.items[0] | select(. != null) | "\(.userTaskKey) \(.elementId)"'
}

instance_state_if_done() {
  local state
  state=$(api GET "/process-instances/$1" | jq -r .state)
  [ "$state" = "COMPLETED" ] || [ "$state" = "TERMINATED" ] && echo "$state" || true
}

wait_for_instance() { # TICKET_ID -> instance key
  local key
  if ! key=$(poll instance_key "$1"); then
    echo "error: no process instance found for $1 (runId $RUN_ID) within ${TIMEOUT_SECONDS}s" >&2
    return 1
  fi
  echo "$key"
}

complete_user_tasks() {
  local id t key task task_key element expected_element vars
  for id in $(ticket_ids); do
    t=$(ticket "$id")
    expected_element=$(echo "$t" | jq -r '.expected.userTask.elementId // empty')
    [ -z "$expected_element" ] && continue
    key=$(wait_for_instance "$id")
    if ! task=$(poll open_user_task "$key"); then
      echo "error: $id reached no user task within ${TIMEOUT_SECONDS}s" >&2
      return 1
    fi
    task_key=${task%% *}; element=${task##* }
    if [ "$element" != "$expected_element" ]; then
      echo "error: $id waits at '$element', expected '$expected_element'" >&2
      return 1
    fi
    vars=$(echo "$t" | jq -c '{variables: .expected.userTask.variables}')
    api POST "/user-tasks/$task_key/completion" "$vars" > /dev/null
    echo "completed user task $element for $id (taskKey $task_key)"
  done
}

print_user_tasks() {
  local id t key task expected_element
  for id in $(ticket_ids); do
    t=$(ticket "$id")
    expected_element=$(echo "$t" | jq -r '.expected.userTask.elementId // empty')
    [ -z "$expected_element" ] && continue
    key=$(wait_for_instance "$id")
    if ! task=$(poll open_user_task "$key"); then
      echo "error: $id reached no user task within ${TIMEOUT_SECONDS}s" >&2
      return 1
    fi
    echo "$id waits at ${task##* } — userTaskKey ${task%% *}"
  done
  echo "complete both in Tasklist, then run: send-tickets.sh --check"
}

variable_value() { # INSTANCE_KEY NAME — unwraps JSON-encoded string values
  api POST /variables/search "$(jq -cn --arg k "$1" --arg n "$2" '{filter: {processInstanceKey: $k, name: $n}}')" \
    | jq -r '.items[0].value // empty | (try fromjson catch .) | tostring'
}

# routing_vars INSTANCE_KEY — one object {name: value} for the DMN routing outputs;
# variable values arrive JSON-encoded, hence fromjson
routing_vars() {
  api POST /variables/search "$(jq -cn --arg k "$1" \
    '{filter: {processInstanceKey: $k, name: {"$in": ["team","priority","slaHours","requiredChecks","slaDeadline","bookingValueEur","refundAmountCustomer"]}}}')" \
    | jq -c '[.items[] | {(.name): (.value | try fromjson catch .)}] | add // {}'
}

verify() {
  echo "run $RUN_ID: verifying"
  local id t key state actual expected fails=0 resolution template exp_res
  local routing actual_routing expected_routing sla_deadline
  local bve rac has_bv is_refund fx_fail count dedup_line=""
  for id in $(ticket_ids); do
    t=$(ticket "$id")
    if ! key=$(wait_for_instance "$id"); then fails=$((fails+1)); echo "FAIL $id: instance not found"; continue; fi
    count=$(instance_count "$id")
    if [ "$count" != "1" ]; then
      echo "FAIL $id: expected exactly 1 instance for (runId, ticketId), got $count"
      fails=$((fails+1)); continue
    fi
    [ "$id" = "T-1001" ] && dedup_line="PASS dedup: duplicate messageId for T-1001 ignored"
    if ! state=$(poll instance_state_if_done "$key"); then
      echo "FAIL $id: instance $key not completed after ${TIMEOUT_SECONDS}s"; fails=$((fails+1)); continue
    fi
    if [ "$state" != "COMPLETED" ]; then
      echo "FAIL $id: instance $key state $state"; fails=$((fails+1)); continue
    fi
    actual=$(api POST /element-instances/search "$(jq -cn --arg k "$key" '{filter: {processInstanceKey: $k, state: "COMPLETED"}}')" \
      | jq -c --arg pid "$PROCESS_ID" '[.items[].elementId | select(. != $pid)] | unique')
    expected=$(echo "$t" | jq -c '.expected.path | unique')
    resolution=$(variable_value "$key" resolution)
    template=$(variable_value "$key" notificationTemplate)
    exp_res=$(echo "$t" | jq -r '.expected.resolution')
    routing=$(routing_vars "$key")
    # requiredChecks compared as a set (sorted); jq -S normalises key order
    actual_routing=$(echo "$routing" | jq -cS '{team, priority, slaHours, requiredChecks: ((.requiredChecks // []) | sort)}')
    expected_routing=$(echo "$t" | jq -cS '.expected.routing | {team, priority, slaHours, requiredChecks: (.requiredChecks | sort)}')
    sla_deadline=$(echo "$routing" | jq -r '.slaDeadline // empty')
    # FX checks: bookingValueEur only where the ticket has a bookingValue; the refund
    # conversion only on the cancel branch
    bve=$(echo "$routing" | jq -r '.bookingValueEur // empty')
    rac=$(echo "$routing" | jq -r '.refundAmountCustomer // empty')
    has_bv=$(echo "$t" | jq -r '.bookingValue != null')
    is_refund=$(echo "$t" | jq -r '.expected.resolution == "refund_issued"')
    fx_fail=""
    if [ "$has_bv" = "true" ]; then
      { [ -n "$bve" ] && awk -v v="$bve" 'BEGIN { exit !(v > 0) }'; } \
        || fx_fail="bookingValueEur='$bve', expected > 0"
    elif [ -n "$bve" ] && [ "$bve" != "null" ]; then
      fx_fail="bookingValueEur='$bve', expected absent (no bookingValue)"
    fi
    if [ -z "$fx_fail" ] && [ "$is_refund" = "true" ]; then
      { [ -n "$rac" ] && awk -v v="$rac" 'BEGIN { exit !(v > 0) }'; } \
        || fx_fail="refundAmountCustomer='$rac', expected > 0"
    fi
    if [ "$actual" != "$expected" ]; then
      echo "FAIL $id: path $actual, expected $expected"; fails=$((fails+1))
    elif [ "$resolution" != "$exp_res" ] || [ "$template" != "notify-$exp_res" ]; then
      echo "FAIL $id: resolution=$resolution notificationTemplate=$template, expected $exp_res / notify-$exp_res"
      fails=$((fails+1))
    elif [ "$actual_routing" != "$expected_routing" ]; then
      echo "FAIL $id: routing $actual_routing, expected $expected_routing"; fails=$((fails+1))
    elif [ -z "$sla_deadline" ]; then
      echo "FAIL $id: slaDeadline is missing or empty"; fails=$((fails+1))
    elif [ -n "$fx_fail" ]; then
      echo "FAIL $id: $fx_fail"; fails=$((fails+1))
    else
      echo "PASS $id: path ok, resolution=$resolution, routing ok, slaDeadline=$sla_deadline"
    fi
  done
  [ -n "$dedup_line" ] && echo "$dedup_line"
  [ "$fails" -eq 0 ] || { echo "$fails ticket(s) failed"; exit 1; }
  echo "all tickets passed"
}

# --check only: consume support.ticket.resolved and match this run's outcome events.
# kcat is required for consuming; without it the check is skipped with a warning.
check_resolved_topic() {
  local broker="${KAFKA_BROKER:-${STAND_IP:-}:9092}"
  if ! command -v kcat >/dev/null 2>&1; then
    echo "WARN: kcat not found — skipping resolved-topic check"
    return 0
  fi
  if [ "$broker" = ":9092" ]; then
    echo "WARN: KAFKA_BROKER/STAND_IP not set — skipping resolved-topic check"
    return 0
  fi
  local total lookback events fails=0 id t exp_res is_refund ev res rac
  total=$(ticket_ids | wc -l | tr -d ' ')
  lookback=$((total * 3)) # headroom for earlier runs still in the topic
  events=$(kcat -b "$broker" -t "$RESOLVED_TOPIC" -C -o "-$lookback" -e -q 2>/dev/null \
    | jq -Rc --arg run "$RUN_ID" 'fromjson? | select(.runId? == $run)')
  for id in $(ticket_ids); do
    t=$(ticket "$id")
    exp_res=$(echo "$t" | jq -r '.expected.resolution')
    is_refund=$(echo "$t" | jq -r '.expected.resolution == "refund_issued"')
    ev=$(echo "$events" | jq -c --arg id "$id" 'select(.ticketId == $id)' | head -n 1)
    if [ -z "$ev" ]; then
      echo "FAIL resolved: no ${RESOLVED_TOPIC} event for $id (runId $RUN_ID)"
      fails=$((fails+1)); continue
    fi
    res=$(echo "$ev" | jq -r '.resolution // empty')
    rac=$(echo "$ev" | jq -r '.refundAmountCustomer // empty')
    if [ "$res" != "$exp_res" ]; then
      echo "FAIL resolved: $id resolution=$res, expected $exp_res"; fails=$((fails+1))
    elif [ "$is_refund" = "true" ] && ! { [ -n "$rac" ] && awk -v v="$rac" 'BEGIN { exit !(v > 0) }'; }; then
      echo "FAIL resolved: $id refundAmountCustomer='$rac', expected > 0"; fails=$((fails+1))
    else
      echo "PASS resolved: $id resolution=$res"
    fi
  done
  [ "$fails" -eq 0 ] || { echo "$fails resolved event(s) failed"; exit 1; }
  echo "resolved-topic check passed"
}

MODE=${1:-default}
case "$MODE" in
  default)
    publish_tickets
    complete_user_tasks
    verify
    ;;
  --manual-user-tasks)
    publish_tickets
    print_user_tasks
    ;;
  --check)
    if [ ! -f "$LAST_RUN_FILE" ]; then
      echo "error: $LAST_RUN_FILE not found — publish a run first" >&2; exit 1
    fi
    RUN_ID=$(cat "$LAST_RUN_FILE")
    verify
    check_resolved_topic
    ;;
  *)
    echo "usage: $0 [--manual-user-tasks | --check]" >&2; exit 2
    ;;
esac

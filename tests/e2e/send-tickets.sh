#!/usr/bin/env bash
# E2E test for support-request-v1 (design §8). Publishes the five tickets from tickets.json,
# completes user tasks over REST (or leaves them for Tasklist with --manual-user-tasks),
# then verifies path, resolution and notificationTemplate per ticket.
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
MESSAGE_NAME=ticket.created
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

publish_tickets() {
  RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
  echo "run $RUN_ID: publishing ${MESSAGE_NAME} for $(ticket_ids | wc -l | tr -d ' ') tickets"
  local id body
  for id in $(ticket_ids); do
    body=$(ticket "$id" | jq -c --arg run "$RUN_ID" '{
      name: "'"$MESSAGE_NAME"'",
      correlationKey: .ticketId,
      messageId: (.ticketId + "-" + $run),
      variables: (del(.expected) + {runId: $run})
    }')
    api POST /messages/publication "$body" > /dev/null
    echo "published $id (messageId $id-$RUN_ID)"
  done
  echo "$RUN_ID" > "$LAST_RUN_FILE"
}

# v2 variable filters compare JSON-encoded values: "T-1001" must be sent as "\"T-1001\""
instance_key() {
  api POST /process-instances/search "$(jq -cn --arg pid "$PROCESS_ID" --arg run "$RUN_ID" --arg id "$1" \
    '{filter: {processDefinitionId: $pid, variables: [{name:"runId",value:($run|tojson)},{name:"ticketId",value:($id|tojson)}]}}')" \
    | jq -r '.items[0].processInstanceKey // empty'
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
    '{filter: {processInstanceKey: $k, name: {"$in": ["team","priority","slaHours","requiredChecks","slaDeadline"]}}}')" \
    | jq -c '[.items[] | {(.name): (.value | try fromjson catch .)}] | add // {}'
}

verify() {
  echo "run $RUN_ID: verifying"
  local id t key state actual expected fails=0 resolution template exp_res
  local routing actual_routing expected_routing sla_deadline
  for id in $(ticket_ids); do
    t=$(ticket "$id")
    if ! key=$(wait_for_instance "$id"); then fails=$((fails+1)); echo "FAIL $id: instance not found"; continue; fi
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
    if [ "$actual" != "$expected" ]; then
      echo "FAIL $id: path $actual, expected $expected"; fails=$((fails+1))
    elif [ "$resolution" != "$exp_res" ] || [ "$template" != "notify-$exp_res" ]; then
      echo "FAIL $id: resolution=$resolution notificationTemplate=$template, expected $exp_res / notify-$exp_res"
      fails=$((fails+1))
    elif [ "$actual_routing" != "$expected_routing" ]; then
      echo "FAIL $id: routing $actual_routing, expected $expected_routing"; fails=$((fails+1))
    elif [ -z "$sla_deadline" ]; then
      echo "FAIL $id: slaDeadline is missing or empty"; fails=$((fails+1))
    else
      echo "PASS $id: path ok, resolution=$resolution, routing ok, slaDeadline=$sla_deadline"
    fi
  done
  [ "$fails" -eq 0 ] || { echo "$fails ticket(s) failed"; exit 1; }
  echo "all tickets passed"
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
    ;;
  *)
    echo "usage: $0 [--manual-user-tasks | --check]" >&2; exit 2
    ;;
esac

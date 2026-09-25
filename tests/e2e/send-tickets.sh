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
#   send-tickets.sh --probe-unknown-booking
#                                       negative probe (never part of the default run): one
#                                       cancel ticket with an unknown bookingRef → BPMN error
#                                       BOOKING_NOT_FOUND has no boundary event yet → incident
#                                       on cancel-refund (Phase 6 scenario B input)
#
# Env contract (same as workers/llm-classifier): CAMUNDA_BASE_URL, CAMUNDA_USER, CAMUNDA_PASSWORD.
# --check additionally needs STAND_HOST (SSH alias) for the classification_review query.
set -euo pipefail

cd "$(dirname "$0")"
TICKETS_FILE=tickets.json
LAST_RUN_FILE=.last-run
PROCESS_ID=support-request-v1
TOPIC=support.ticket.created
RESOLVED_TOPIC=support.ticket.resolved
TIMEOUT_SECONDS=60
POLL_INTERVAL=2
# slaDeadline must be plain ISO 8601 with a zone — no engine [GMT] suffix (D3-11, process v7)
ISO_ZONED_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
REVIEW_TICKET=T-1004   # the one ticket with a hard review expectation (design §8)

for var in CAMUNDA_BASE_URL CAMUNDA_USER CAMUNDA_PASSWORD; do
  if [ -z "${!var:-}" ]; then
    echo "error: $var is not set (same contract as workers/llm-classifier, see its .env.example)" >&2
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

# Closes user tasks until each instance finishes. review-classification is closed for
# ANY ticket where it appears (borderline LLM confidence can send any ticket to review —
# design D5-2 note), keeping the current intent so the route is unchanged; only tickets
# with expected.userTask get their scripted variables. Whether T-1004 actually visited
# review is asserted by the path check in verify().
complete_user_tasks() {
  local id t key expected_element deadline state task task_key element vars intent_now
  for id in $(ticket_ids); do
    t=$(ticket "$id")
    expected_element=$(echo "$t" | jq -r '.expected.userTask.elementId // empty')
    key=$(wait_for_instance "$id") || return 1
    deadline=$((SECONDS + TIMEOUT_SECONDS))
    while [ "$SECONDS" -lt "$deadline" ]; do
      state=$(instance_state_if_done "$key")
      [ -n "$state" ] && break
      task=$(open_user_task "$key")
      if [ -n "$task" ]; then
        task_key=${task%% *}; element=${task##* }
        if [ "$element" = "review-classification" ]; then
          if [ "$expected_element" = "review-classification" ]; then
            vars=$(echo "$t" | jq -c '{variables: .expected.userTask.variables}')
          else
            intent_now=$(variable_value "$key" intent)
            vars=$(jq -cn --arg i "$intent_now" \
              '{variables: {intent: $i, needsReview: false, escalate: false}}')
          fi
          api POST "/user-tasks/$task_key/completion" "$vars" > /dev/null
          echo "completed user task review-classification for $id (taskKey $task_key)"
        elif [ "$element" = "handle-by-agent" ]; then
          if [ "$expected_element" = "handle-by-agent" ]; then
            vars=$(echo "$t" | jq -c '{variables: .expected.userTask.variables}')
          else
            echo "WARN: unexpected handle-by-agent for $id — closing it; verify judges by resolution"
            vars='{"variables":{"agentNote":"closed by e2e (unexpected escalation)"}}'
          fi
          api POST "/user-tasks/$task_key/completion" "$vars" > /dev/null
          echo "completed user task handle-by-agent for $id (taskKey $task_key)"
        fi
      fi
      sleep "$POLL_INTERVAL"
    done
  done
}

# Lists every open user task of the run, not only the expected ones: borderline
# confidence can send any ticket to review (T-1006 does on most runs). Each instance is
# polled until it waits at a user task or finishes; the loop is capped at TIMEOUT_SECONDS
# per ticket, and an instance stuck elsewhere (e.g. an incident on a service task) is
# printed as "no user task, state=ACTIVE" instead of being waited on. Tickets with an
# expected user task must reach one — anything else is an error.
print_user_tasks() {
  local id t key task expected_element deadline state listed=0 fails=0
  for id in $(ticket_ids); do
    t=$(ticket "$id")
    expected_element=$(echo "$t" | jq -r '.expected.userTask.elementId // empty')
    if ! key=$(wait_for_instance "$id"); then fails=$((fails+1)); continue; fi
    deadline=$((SECONDS + TIMEOUT_SECONDS)); task=""; state=""
    while [ "$SECONDS" -lt "$deadline" ]; do
      task=$(open_user_task "$key")
      [ -n "$task" ] && break
      state=$(instance_state_if_done "$key")
      [ -n "$state" ] && break
      sleep "$POLL_INTERVAL"
    done
    if [ -n "$task" ]; then
      echo "open user task: ${task##* }  ticketId=$id  userTaskKey=${task%% *}"
      listed=$((listed+1))
    elif [ -n "$expected_element" ]; then
      echo "error: $id reached no user task within ${TIMEOUT_SECONDS}s (expected $expected_element)" >&2
      fails=$((fails+1))
    else
      echo "$id: no user task, state=${state:-ACTIVE}"
    fi
  done
  echo "$listed open user task(s) — complete them in Tasklist, then run: send-tickets.sh --check"
  [ "$fails" -eq 0 ] || exit 1
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

# generation_vars INSTANCE_KEY — the 5.4 LLM outputs (process scope; answer* reach it
# through the v8 output mappings on answer-question, notify-customer has none)
generation_vars() {
  api POST /variables/search "$(jq -cn --arg k "$1" \
    '{filter: {processInstanceKey: $k, name: {"$in": ["customerMessage","messageLanguage","notifySource","answerText","answerSource","answerKbIds"]}}}')" \
    | jq -c '[.items[] | {(.name): (.value | try fromjson catch .)}] | add // {}'
}

# cyrillic_ratio — stdin text → share of Cyrillic letters among all letters (0..1, 2 dp).
# jq instead of awk: macOS awk fails on multibyte input. Letters = ASCII, Latin-1/Extended
# (U+00C0–U+024F) and the Cyrillic block (U+0400–U+04FF).
cyrillic_ratio() {
  jq -Rrs '[explode[] | select((. >= 65 and . <= 90) or (. >= 97 and . <= 122)
                              or (. >= 192 and . <= 591) or (. >= 1024 and . <= 1279))]
           | if length == 0 then 0
             else (map(select(. >= 1024 and . <= 1279)) | length) / length end
           | . * 100 | round / 100'
}

# generation_check TICKET_JSON ROUTING_JSON GENERATION_JSON — prints a failure reason or
# nothing (5.4, D5-8/D5-9): customerMessage present in the ticket language for every
# ticket; the answered branch carries answerText + answerKbIds; the refund message
# names refundAmountCustomer (numeric match, so 320.5 and 320.50 both pass)
generation_check() {
  local t=$1 routing=$2 gen=$3 lang msg msg_lang exp_res rac
  lang=$(echo "$t" | jq -r '.language')
  exp_res=$(echo "$t" | jq -r '.expected.resolution')
  msg=$(echo "$gen" | jq -r '.customerMessage // empty')
  msg_lang=$(echo "$gen" | jq -r '.messageLanguage // empty')
  if [ -z "$msg" ]; then echo "customerMessage missing or empty"; return; fi
  if [ "$msg_lang" != "$lang" ]; then echo "messageLanguage='$msg_lang', expected '$lang'"; return; fi
  # cheap script sanity check: share of Cyrillic among letters — ru > 0.5, en < 0.1
  local ratio
  ratio=$(printf '%s' "$msg" | cyrillic_ratio)
  case "$lang" in
    ru) awk -v r="$ratio" 'BEGIN { exit !(r > 0.5) }' || { echo "Cyrillic ratio $ratio, expected > 0.5 for ru"; return; } ;;
    en) awk -v r="$ratio" 'BEGIN { exit !(r < 0.1) }' || { echo "Cyrillic ratio $ratio, expected < 0.1 for en"; return; } ;;
  esac
  if [ "$exp_res" = "answered" ]; then
    if [ -z "$(echo "$gen" | jq -r '.answerText // empty')" ]; then echo "answerText missing or empty"; return; fi
    if [ "$(echo "$gen" | jq -r '.answerKbIds // [] | length')" = "0" ]; then echo "answerKbIds empty"; return; fi
  fi
  if [ "$exp_res" = "refund_issued" ]; then
    rac=$(echo "$routing" | jq -r '.refundAmountCustomer // empty')
    if ! echo "$msg" | grep -oE '[0-9]+([.,][0-9]+)?' | tr ',' '.' \
         | awk -v v="$rac" 'BEGIN { ok = 0 } { if ($1 + 0 == v + 0) ok = 1 } END { exit !ok }'; then
      echo "customerMessage does not contain refundAmountCustomer=$rac: $(echo "$msg" | tr '\n' ' ' | cut -c1-120)"; return
    fi
  fi
}

verify() {
  echo "run $RUN_ID: verifying"
  local id t key state actual expected path_fail fails=0 resolution template exp_res
  local routing actual_routing expected_routing sla_deadline gen gen_fail
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
    # Path check by final resolution: the expected path must be fully present, and any
    # extra elements may only be the review detour (borderline confidence can send any
    # ticket there — D5-2 note); since v7 the detour is review-classification →
    # record-review → gw-review-exit → route-ticket (D5-4). T-1004 keeps its hard review
    # expectation because review-classification is part of its expected.path.
    actual=$(api POST /element-instances/search "$(jq -cn --arg k "$key" '{filter: {processInstanceKey: $k, state: "COMPLETED"}}')" \
      | jq -c --arg pid "$PROCESS_ID" '[.items[].elementId | select(. != $pid)] | unique')
    expected=$(echo "$t" | jq -c '.expected.path | unique')
    path_fail=$(jq -cn --argjson a "$actual" --argjson e "$expected" '
      {missing: ($e - $a), extra: (($a - $e) - ["review-classification", "record-review", "gw-review-exit"])}
      | if .missing == [] and .extra == [] then empty else . end')
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
    gen=$(generation_vars "$key")
    gen_fail=$(generation_check "$t" "$routing" "$gen")
    if [ -n "$path_fail" ]; then
      echo "FAIL $id: path mismatch $path_fail (actual $actual)"; fails=$((fails+1))
    elif [ "$resolution" != "$exp_res" ] || [ "$template" != "notify-$exp_res" ]; then
      echo "FAIL $id: resolution=$resolution notificationTemplate=$template, expected $exp_res / notify-$exp_res"
      fails=$((fails+1))
    elif [ "$actual_routing" != "$expected_routing" ]; then
      echo "FAIL $id: routing $actual_routing, expected $expected_routing"; fails=$((fails+1))
    elif [ -z "$sla_deadline" ]; then
      echo "FAIL $id: slaDeadline is missing or empty"; fails=$((fails+1))
    elif ! [[ "$sla_deadline" =~ $ISO_ZONED_RE ]]; then
      echo "FAIL $id: slaDeadline='$sla_deadline' is not plain ISO 8601 with zone (D3-11)"; fails=$((fails+1))
    elif [ -n "$fx_fail" ]; then
      echo "FAIL $id: $fx_fail"; fails=$((fails+1))
    elif [ -n "$gen_fail" ]; then
      echo "FAIL $id: generation: $gen_fail"; fails=$((fails+1))
    else
      echo "PASS $id: path ok, resolution=$resolution, routing ok, slaDeadline=$sla_deadline, message ok ($(echo "$gen" | jq -r '.messageLanguage')/$(echo "$gen" | jq -r '.notifySource // "?"'))"
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

# --check only: the review loop must have written one classification_review row for the
# review ticket of this run (5.3, D5-4): llm_intent as classified, final_intent as corrected
# in the form. Runs psql inside the postgres container over SSH; without STAND_HOST the check
# is skipped with a warning.
check_classification_review() {
  if [ -z "${STAND_HOST:-}" ]; then
    echo "WARN: STAND_HOST not set — skipping classification_review check"
    return 0
  fi
  local exp_llm exp_final sql row
  exp_llm=$(ticket "$REVIEW_TICKET" | jq -r '.expected.review.llmIntent')
  exp_final=$(ticket "$REVIEW_TICKET" | jq -r '.expected.review.finalIntent')
  sql="SELECT llm_intent, final_intent, reviewed_by, escalated FROM classification_review
       WHERE ticket_id = '$REVIEW_TICKET' AND run_id = '$RUN_ID' ORDER BY id DESC LIMIT 1;"
  # SQL travels over stdin (ssh → docker compose exec -T → psql), so no nested quoting
  row=$(printf '%s\n' "$sql" | ssh "$STAND_HOST" \
    'cd /opt/camunda-support-automation/infra && docker compose exec -T postgres sh -c '"'"'psql -q -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB"'"'"'' \
    | tail -n1)
  if [ -z "$row" ]; then
    echo "FAIL review: no classification_review row for $REVIEW_TICKET (runId $RUN_ID)"; exit 1
  fi
  local llm final
  IFS='|' read -r llm final _ <<< "$row"
  if [ "$llm" != "$exp_llm" ] || [ "$final" != "$exp_final" ]; then
    echo "FAIL review: $REVIEW_TICKET llm_intent=$llm final_intent=$final, expected $exp_llm/$exp_final ($row)"
    exit 1
  fi
  echo "PASS review: $REVIEW_TICKET classification_review row $row"
}

# open_incident INSTANCE_KEY -> "elementId errorType: errorMessage" of the first active incident
open_incident() {
  api POST /incidents/search "$(jq -cn --arg k "$1" '{filter: {processInstanceKey: $k, state: "ACTIVE"}}')" \
    | jq -r '.items[0] | select(. != null) | "\(.elementId) \(.errorType): \(.errorMessage)"'
}

# Negative probe: produces one cancel_refund ticket whose bookingRef the mock does not
# know, then waits for the incident and prints it. Its own runId; verify() never sees it.
probe_unknown_booking() {
  RUN_ID="probe-$(date -u +%Y%m%dT%H%M%SZ)"
  local id="T-9001" payload key incident
  payload=$(jq -cn --arg id "$id" --arg run "$RUN_ID" '{
    ticketId: $id, customerId: "C-9001", customerTier: "standard",
    subject: "Please cancel and refund", body: "I cannot travel, please cancel my booking and refund it.",
    language: "en", bookingRef: "BK-UNKNOWN", bookingValue: 100, currency: "EUR",
    customerCurrency: "EUR", runId: $run, messageId: ($id + "-" + $run)}')
  produce_event "$id" "$payload"
  echo "produced $id (bookingRef BK-UNKNOWN, runId $RUN_ID) — expecting an incident on cancel-refund"
  key=$(wait_for_instance "$id") || exit 1
  if ! incident=$(poll open_incident "$key"); then
    echo "FAIL probe: no incident on instance $key within ${TIMEOUT_SECONDS}s (state $(api GET "/process-instances/$key" | jq -r .state))"
    exit 1
  fi
  echo "PASS probe: instance $key has an incident — $incident"
  echo "resolve or cancel it in Operate (instance key $key); it is not part of any e2e run"
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
  --probe-unknown-booking)
    probe_unknown_booking
    ;;
  --check)
    if [ ! -f "$LAST_RUN_FILE" ]; then
      echo "error: $LAST_RUN_FILE not found — publish a run first" >&2; exit 1
    fi
    RUN_ID=$(cat "$LAST_RUN_FILE")
    verify
    check_resolved_topic
    check_classification_review
    ;;
  *)
    echo "usage: $0 [--manual-user-tasks | --check | --probe-unknown-booking]" >&2; exit 2
    ;;
esac

#!/usr/bin/env bash
# Migrate one process instance of support-request-v1 to another deployed version over the
# Orchestration Cluster REST API v2 (Phase 6.2, scenario B). Identity mapping: every ACTIVE
# element of the instance is mapped to the element with the same id in the target version,
# which is exactly the v8 → v9 case (the target adds boundary events; a catch event that
# exists only in the target gets its subscription after migration — 8.9 migration concept).
#
#   tests/ops/migrate-instance.sh <processInstanceKey> <targetVersion>
#
# Prints the plan, asks y/N, calls POST /v2/process-instances/{key}/migration and shows the
# result. Does NOT resolve incidents: after a migration the incident is still there and is
# resolved separately (Operate → Retry, or PATCH /v2/jobs/{jobKey} + POST
# /v2/incidents/{incidentKey}/resolution — runbook). Refuses when the instance already runs
# the target version. Endpoint and field names verified against the 8.9 SDK models
# (ProcessInstanceMigrationInstruction, MigrateProcessInstanceMappingInstruction,
# ElementInstanceFilter, ProcessDefinitionFilter).
#
# Env contract (same as tests/e2e): CAMUNDA_BASE_URL, CAMUNDA_USER, CAMUNDA_PASSWORD.
set -euo pipefail

PROCESS_ID=support-request-v1

usage() { echo "usage: $0 <processInstanceKey> <targetVersion>" >&2; exit 2; }
[ $# -eq 2 ] || usage
KEY=$1; TARGET_VERSION=$2
[[ "$KEY" =~ ^[0-9]+$ && "$TARGET_VERSION" =~ ^[0-9]+$ ]] || usage

for var in CAMUNDA_BASE_URL CAMUNDA_USER CAMUNDA_PASSWORD; do
  if [ -z "${!var:-}" ]; then
    echo "error: $var is not set (same contract as tests/e2e/send-tickets.sh)" >&2
    exit 1
  fi
done
BASE="${CAMUNDA_BASE_URL%/}/v2"

api() { # api METHOD PATH [JSON_BODY] — prints the body; non-2xx → message on stderr, non-zero
  local method=$1 path=$2 body=${3:-} out code
  out=$(curl -sS -u "$CAMUNDA_USER:$CAMUNDA_PASSWORD" -X "$method" "$BASE$path" \
    -H 'Content-Type: application/json' ${body:+-d "$body"} -w '\n%{http_code}')
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if [ "${code:0:1}" != "2" ]; then
    echo "error: $method $path -> HTTP $code: $out" >&2
    return 1
  fi
  printf '%s' "$out"
}

# 1. the instance: current definition and version
instance=$(api GET "/process-instances/$KEY")
current_def=$(echo "$instance" | jq -r '.processDefinitionKey')
current_version=$(echo "$instance" | jq -r '.processDefinitionVersion')
current_pid=$(echo "$instance" | jq -r '.processDefinitionId')
state=$(echo "$instance" | jq -r '.state')
if [ "$current_pid" != "$PROCESS_ID" ]; then
  echo "error: instance $KEY belongs to process '$current_pid', not '$PROCESS_ID'" >&2; exit 1
fi
if [ "$state" != "ACTIVE" ]; then
  echo "error: instance $KEY is $state — only ACTIVE instances can be migrated" >&2; exit 1
fi
if [ "$current_version" = "$TARGET_VERSION" ]; then
  echo "error: instance $KEY already runs $PROCESS_ID version $TARGET_VERSION (definition $current_def) — nothing to migrate" >&2
  exit 1
fi

# 2. the target definition key for (processDefinitionId, version)
target_def=$(api POST /process-definitions/search "$(jq -cn --arg pid "$PROCESS_ID" --argjson v "$TARGET_VERSION" \
  '{filter: {processDefinitionId: $pid, version: $v}}')" | jq -r '.items[0].processDefinitionKey // empty')
if [ -z "$target_def" ]; then
  echo "error: $PROCESS_ID version $TARGET_VERSION is not deployed (process-definitions search returned nothing)" >&2
  exit 1
fi

# 3. active elements — the PROCESS element itself is listed as ACTIVE but is never mapped
active=$(api POST /element-instances/search "$(jq -cn --arg k "$KEY" \
  '{filter: {processInstanceKey: $k, state: "ACTIVE"}, page: {limit: 100}}')" \
  | jq -c '[.items[] | select(.type != "PROCESS") | {elementId, type, hasIncident, elementInstanceKey}]')
if [ "$(echo "$active" | jq 'length')" = "0" ]; then
  echo "error: instance $KEY has no active element (nothing to map)" >&2; exit 1
fi

# 4. identity mapping plan
plan=$(jq -cn --arg t "$target_def" --argjson a "$active" --argjson ref "$(date +%s)" '{
  targetProcessDefinitionKey: $t,
  mappingInstructions: [$a[] | {sourceElementId: .elementId, targetElementId: .elementId}],
  operationReference: $ref}')

echo "instance        $KEY ($PROCESS_ID v$current_version, definition $current_def, $state)"
echo "target          $PROCESS_ID v$TARGET_VERSION, definition $target_def"
echo "active elements:"
echo "$active" | jq -r '.[] | "  \(.elementId)  \(.type)  incident=\(.hasIncident)  elementInstanceKey=\(.elementInstanceKey)"'
echo "request         POST /v2/process-instances/$KEY/migration"
echo "$plan" | jq .
echo "note: an incident on an active element is carried over and must be resolved after the migration (Retry in Operate)"
read -r -p "migrate? [y/N] " answer
[ "$answer" = "y" ] || { echo "aborted"; exit 3; }

api POST "/process-instances/$KEY/migration" "$plan" >/dev/null
echo "migration accepted (HTTP 204)"

# 5. confirm: the instance now reports the target version (eventually consistent — retry briefly)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  after=$(api GET "/process-instances/$KEY")
  v=$(echo "$after" | jq -r '.processDefinitionVersion')
  if [ "$v" = "$TARGET_VERSION" ]; then
    echo "instance $KEY now on $PROCESS_ID v$v (definition $(echo "$after" | jq -r .processDefinitionKey))"
    echo "next: resolve the incident, if any — Operate → Retry, or the API calls in docs/runbooks/migration.md §6"
    exit 0
  fi
  sleep 1
done
echo "warning: the instance still reports version $v after 10 s (secondary storage lag?) — check Operate" >&2
exit 0

#!/usr/bin/env bash
# Create the technical user `worker` and its authorizations on the RUNNING stand (Phase 6.5,
# docs/design/operations-v1.md §7, docs/ops/install.md "Worker user"). Users from
# camunda.security.initialization apply only to a fresh secondary storage, so this goes
# through the REST API v2 as admin. Idempotent: re-running reports what exists and adds
# only what is missing. Never prints a password. Run on the stand host:
#   tests/ops/create-worker-user.sh              # resource id support-request-v1 (the plan)
#   tests/ops/create-worker-user.sh --wildcard   # resource id "*" — fallback if job
#                                                # activation is refused per process id
#   tests/ops/create-worker-user.sh --verify     # checks only (negative + positive proof)
. "$(dirname "$0")/_lib.sh"
: "${CAMUNDA_WORKER_PASSWORD:?set CAMUNDA_WORKER_PASSWORD in infra/.env}"
WORKER_USER=worker
PROCESS_ID=support-request-v1
RESOURCE_ID=$PROCESS_ID
MODE=create
case "${1:-}" in
  --wildcard) RESOURCE_ID='*' ;;
  --verify)   MODE=verify ;;
  "")         ;;
  *) echo "usage: $0 [--wildcard | --verify]" >&2; exit 2 ;;
esac
# minimal set (8.9 authorization reference, "API access" and "User task authorizations"):
#   UPDATE_PROCESS_INSTANCE — activate / complete / fail / throw-error for every job of the process
#   READ_USER_TASK          — sla.escalate searches the open agent task (sla.py)
#   UPDATE_USER_TASK        — sla.escalate raises its priority and sets the candidate group
PERMISSIONS='["UPDATE_PROCESS_INSTANCE","READ_USER_TASK","UPDATE_USER_TASK"]'

# HTTP status of a v2 call as a given user: code USER PASSWORD METHOD PATH [JSON]
code() {
  local u=$1 pw=$2 m=$3 p=$4 b=${5:-}
  if [ -n "$b" ]; then curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -u "$u:$pw" -X "$m" "$API$p" -H 'Content-Type: application/json' -d "$b"
  else curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -u "$u:$pw" -X "$m" "$API$p"; fi
}

if [ "$MODE" = create ]; then
  # 1. user
  if [ "$(code admin "$CAMUNDA_ADMIN_PASSWORD" GET "/users/$WORKER_USER")" = "200" ]; then
    log "user $WORKER_USER exists"
  else
    st=$(code admin "$CAMUNDA_ADMIN_PASSWORD" POST /users \
      "$(jq -cn --arg u "$WORKER_USER" --arg p "$CAMUNDA_WORKER_PASSWORD" '{username: $u, password: $p, name: "Worker", email: "worker@example.com"}')")
    [ "$st" = "201" ] || fail "POST /users returned $st"
    log "user $WORKER_USER created"
  fi

  # 2. authorization — one entry per (owner, resource type, resource id) carrying the set
  existing=$(api POST /authorizations/search \
    "$(jq -cn --arg o "$WORKER_USER" '{filter: {ownerId: $o, ownerType: "USER", resourceType: "PROCESS_DEFINITION"}}')")
  have=$(printf '%s' "$existing" | jq -r --arg r "$RESOURCE_ID" '[.items[]? | select(.resourceId == $r) | .permissionTypes[]] | unique | join(",")')
  want=$(printf '%s' "$PERMISSIONS" | jq -r 'sort | join(",")')
  if [ -n "$have" ] && [ "$(printf '%s' "$have" | tr ',' '\n' | sort | paste -sd, -)" = "$want" ]; then
    log "authorization for PROCESS_DEFINITION $RESOURCE_ID exists: $have"
  elif [ -n "$have" ]; then
    fail "authorization for PROCESS_DEFINITION $RESOURCE_ID exists with a different set ($have); remove it in the Admin UI (/admin → Authorizations) and re-run"
  else
    st=$(code admin "$CAMUNDA_ADMIN_PASSWORD" POST /authorizations \
      "$(jq -cn --arg o "$WORKER_USER" --arg r "$RESOURCE_ID" --argjson p "$PERMISSIONS" \
          '{ownerId: $o, ownerType: "USER", resourceId: $r, resourceType: "PROCESS_DEFINITION", permissionTypes: $p}')")
    [ "$st" = "201" ] || fail "POST /authorizations returned $st"
    log "authorization created: PROCESS_DEFINITION $RESOURCE_ID $(printf '%s' "$PERMISSIONS" | jq -r 'join(",")')"
  fi
  echo "authorizations of $WORKER_USER:"
  api POST /authorizations/search "$(jq -cn --arg o "$WORKER_USER" '{filter: {ownerId: $o, ownerType: "USER"}}')" \
    | jq -r '.items[]? | "  \(.resourceType)  \(.resourceId)  \(.permissionTypes | join(","))"'
fi

# 3. proof, zero side effects either way
#    negative: GET one process definition — READ_PROCESS_DEFINITION is not granted → 403 as
#    worker, 200 as admin (control). A single GET, not a search: searches filter, they do not 403.
#    positive: POST /user-tasks/search as worker → 200 (READ_USER_TASK). Job activation is
#    proven by the e2e run, not here (an activation would take a real job).
key=$(api POST /process-definitions/search "$(jq -cn --arg id "$PROCESS_ID" '{filter: {processDefinitionId: $id, isLatestVersion: true}, page: {limit: 1}}')" | jq -r '.items[0].processDefinitionKey // empty')
[ -n "$key" ] || fail "no deployed process $PROCESS_ID"
neg=$(code "$WORKER_USER" "$CAMUNDA_WORKER_PASSWORD" GET "/process-definitions/$key")
ctl=$(code admin "$CAMUNDA_ADMIN_PASSWORD" GET "/process-definitions/$key")
pos=$(code "$WORKER_USER" "$CAMUNDA_WORKER_PASSWORD" POST /user-tasks/search '{"page":{"limit":1}}')
[ "$neg" = "403" ] && echo "PASS negative proof: GET /process-definitions/$key as $WORKER_USER → 403" || echo "FAIL negative proof: GET /process-definitions/$key as $WORKER_USER → $neg (expected 403)"
[ "$ctl" = "200" ] && echo "PASS control: same GET as admin → 200" || echo "FAIL control: same GET as admin → $ctl (expected 200)"
[ "$pos" = "200" ] && echo "PASS positive proof: POST /user-tasks/search as $WORKER_USER → 200" || echo "FAIL positive proof: POST /user-tasks/search as $WORKER_USER → $pos (expected 200)"
[ "$neg" = "403" ] && [ "$ctl" = "200" ] && [ "$pos" = "200" ]

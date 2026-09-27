#!/usr/bin/env bash
# One line per fact about the stand's state — run before a backup and after a restore and
# diff the two outputs (Phase 6.4). Public REST API v2 + psql + the backup stores.
#   tests/ops/verify-state.sh [> before.txt]
. "$(dirname "$0")/_lib.sh"
topo=$(api GET /topology)
echo "gatewayVersion      $(echo "$topo" | jq -r '.gatewayVersion')"
echo "brokerVersion       $(echo "$topo" | jq -r '.brokers[0].version')"
latest=$(api POST /process-definitions/search '{"filter":{"processDefinitionId":"support-request-v1","isLatestVersion":true}}')
echo "latestVersion       $(echo "$latest" | jq -r '.items[0].version // "none"') (key $(echo "$latest" | jq -r '.items[0].processDefinitionKey // "-"'))"
echo "definitionsTotal    $(api POST /process-definitions/search '{"filter":{"processDefinitionId":"support-request-v1"},"page":{"limit":1}}' | jq -r '.page.totalItems')"
for st in ACTIVE COMPLETED TERMINATED; do
  echo "instances $st  $(api POST /process-instances/search "{\"filter\":{\"processDefinitionId\":\"support-request-v1\",\"state\":\"$st\"},\"page\":{\"limit\":1}}" | jq -r '.page.totalItems')"
done
echo "incidents ACTIVE    $(api POST /incidents/search '{"filter":{"state":"ACTIVE"},"page":{"limit":1}}' | jq -r '.page.totalItems')"
echo "userTasks CREATED   $(api POST /user-tasks/search '{"filter":{"state":"CREATED"},"page":{"limit":1}}' | jq -r '.page.totalItems')"
for t in llm_audit classification_review sla_escalation; do
  echo "rows $t  $(docker compose exec -T postgres sh -c 'psql -q -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select count(*) from '"$t"'"' 2>/dev/null || echo '?')"
done
# integrity: the newest instances must carry a startDate — a null startDate after a restore
# means the instance was rebuilt from re-exported completion records (observed 2026-09-27)
api POST /process-instances/search '{"filter":{"processDefinitionId":"support-request-v1"},"sort":[{"field":"processInstanceKey","order":"DESC"}],"page":{"limit":3}}' \
  | jq -r '.items[] | "newest instance     \(.processInstanceKey)  \(.state)  start=\(.startDate // "null")  end=\(.endDate // "-")"'
echo "esIndices           $(es_curl "$ES/_cat/indices?h=index" | grep -cE 'camunda|operate|tasklist|zeebe' || true)"
echo "esSnapshots         $(es_curl "$ES/_snapshot/$REPO/_all" 2>/dev/null | jq -r '.snapshots | length' 2>/dev/null || echo 'no repo')"
echo "zeebeBackups        $(mgmt GET /actuator/backupRuntime 2>/dev/null | jq -r 'if type=="array" then length else "n/a: " + (.message // .error // tostring) end' 2>/dev/null)"

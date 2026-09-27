#!/usr/bin/env bash
# Full backup of the stand (Phase 6.4, 8.9 backup guide, Elasticsearch path):
#   0b wait until the exporter has acknowledged every processed record (mitigation A, §6) →
#   1 soft-pause exporting → 2 web-apps backup (backupHistory) → poll →
#   3 snapshot of zeebe-record* only if such indices exist (Camunda Exporter: normally none) →
#   4 Zeebe partition backup (backupRuntime) → poll → 5 resume exporting → 6 pg_dump.
# One backupId (unix seconds, monotonic) names the whole set. Exporting is resumed by a trap
# on any failure. Run on the stand host:
#   tests/ops/backup.sh            # id = date +%s
#   tests/ops/backup.sh <id>       # explicit id (must be greater than every previous id)
. "$(dirname "$0")/_lib.sh"
ID=${1:-$(date +%s)}
[[ "$ID" =~ ^[0-9]+$ ]] || fail "backupId must be an integer"

paused=0
resume() {
  if [ "$paused" = 1 ]; then
    st=$(mgmt POST /actuator/exporting/resume | jq -r '.status // "?"')
    log "exporting resumed (status $st)"; paused=0
  fi
}
trap resume EXIT

# 0. snapshot repository — idempotent registration + verify
ensure_repo

log "backup set $ID"
# 0b. exporter sync (mitigation A, runbook §6): abort rather than pause with a lagging exporter.
#     Runs before the pause, so nothing has to be undone when it fails.
wait_exporter_sync "$EXPORTER_SYNC_TIMEOUT"

# 1. soft pause (HTTP 200 always; .status 204 = ok)
st=$(mgmt POST "/actuator/exporting/pause?soft=true" | jq -r '.status // "?"')
[ "$st" = "204" ] || fail "exporting pause returned status $st"
paused=1; log "exporting soft-paused"

# 2. web-apps backup
mgmt POST /actuator/backupHistory "{\"backupId\": $ID}" | jq -c .
history_state() { mgmt GET "/actuator/backupHistory/$ID" | jq -r '.state'; }
poll_state history_state "backupHistory $ID"

# 3. zeebe-record* indices (only with the Elasticsearch/OpenSearch exporter)
records=$(es_curl "$ES/_cat/indices/zeebe-record*?h=index" 2>/dev/null | grep -c . || true)
if [ "${records:-0}" -gt 0 ]; then
  log "$records zeebe-record* indices — snapshotting"
  es_curl -X PUT "$ES/_snapshot/$REPO/camunda_zeebe_records_backup_$ID?wait_for_completion=true" \
    -H 'Content-Type: application/json' -d '{"indices":"zeebe-record*","feature_states":["none"]}' | jq -c '.snapshot | {snapshot, state, indices: (.indices|length)}'
else
  log "no zeebe-record* indices (Camunda Exporter) — step skipped"
fi

# 3b. day-suffixed indices of today and yesterday — explicit snapshot camunda_dated_<id>
#     (belt and braces for the same-day gap seen 2026-09-27: instances completed minutes
#     before the backup came back without startDate). Overlap with the web-apps parts is
#     fine: restore.sh restores from it only what the parts did not bring back.
dated=$(es_curl "$ES/_cat/indices/$(dated_patterns)?h=index&expand_wildcards=open" 2>/dev/null | grep -c . || true)
if [ "${dated:-0}" -gt 0 ]; then
  log "$dated day-suffixed indices ($(dated_patterns)) — snapshotting camunda_dated_$ID"
  es_curl -X PUT "$ES/_snapshot/$REPO/camunda_dated_$ID?wait_for_completion=true" \
    -H 'Content-Type: application/json' -d "{\"indices\":\"$(dated_patterns)\",\"ignore_unavailable\":true,\"include_global_state\":false,\"feature_states\":[\"none\"]}" \
    | jq -c '.snapshot | {snapshot, state, indices: (.indices|length), shards}'
else
  log "no day-suffixed indices for $(dated_patterns) — dated snapshot skipped"
fi

# 4. Zeebe partition backup
mgmt POST /actuator/backupRuntime "{\"backupId\": $ID}" | jq -c .
runtime_state() { mgmt GET "/actuator/backupRuntime/$ID" | jq -r '.state'; }
poll_state runtime_state "backupRuntime $ID"

# 5. resume (trap does it too; explicit here so the summary shows it)
resume

# 6. PostgreSQL
"$(dirname "$0")/pg-backup.sh" "$ID"

echo
echo "backup $ID complete"
echo "snapshots:"; es_curl "$ES/_snapshot/$REPO/_all" | jq -r --arg id "$ID" '(.snapshots // [])[] | select(.snapshot | test($id)) | "  \(.snapshot)  \(.state)"'
echo "zeebe partitions:"; mgmt GET "/actuator/backupRuntime/$ID" | jq -r '.details[] | "  partition \(.partitionId)  \(.state)  \(.brokerVersion)"'
echo "on disk:"; find "$BACKUP_ROOT" -maxdepth 3 -newermt "-1 hour" -type f 2>/dev/null | head -20 | sed 's/^/  /'; du -sh "$BACKUP_ROOT"/* 2>/dev/null | sed 's/^/  /'

#!/usr/bin/env bash
# Restore the stand from a backup set (Phase 6.4, 8.9 restore guide, Elasticsearch path).
# Same image version as the backup is mandatory (the snapshot names carry it).
#   tests/ops/restore.sh <backupId> [--pause-after-seed]
# Order:
#   0 refuse if ACTIVE instances exist (a restore throws the running work away)
#   1 docker compose down; remove the camunda + elastic volumes (backups are bind mounts)
#   2 clean start of elasticsearch + orchestration → index templates are seeded
#     (--pause-after-seed: wait for Enter here — empty Operate for a screenshot)
#   2b re-register the snapshot repository: it is cluster state and went with the volume
#   3 stop orchestration; delete every index matching camunda|operate|tasklist|optimize|zeebe
#   4 restore every snapshot of the set (listed from the repository — the cluster is
#     stopped, backupHistory is not available), one by one, wait_for_completion=true
#   5 remove the camunda volume again (the seed start wrote to it) — data dir must be empty
#   6 bin/restore --backupId=<id> with the same config (SPRING_PROFILES_ACTIVE=restore)
#   7 start everything; pg_restore; verify-state
. "$(dirname "$0")/_lib.sh"
ID=${1:?usage: restore.sh <backupId> [--pause-after-seed]}
PAUSE=${2:-}
[[ "$ID" =~ ^[0-9]+$ ]] || fail "backupId must be an integer"
PROJECT=$(project); [ -n "$PROJECT" ] || fail "cannot determine the compose project name"
[ -f "$BACKUP_ROOT/pg/camunda_support_$ID.dump" ] || fail "no PostgreSQL dump for $ID in $BACKUP_ROOT/pg"
[ -d "$BACKUP_ROOT/zeebe" ] || fail "no Zeebe backup directory $BACKUP_ROOT/zeebe"

# 0. running work?
if active=$(api POST /process-instances/search '{"filter":{"state":"ACTIVE"},"page":{"limit":1}}' 2>/dev/null | jq -r '.page.totalItems' 2>/dev/null); then
  [ "${active:-0}" = "0" ] || fail "$active ACTIVE process instance(s) — finish or cancel them first (a restore discards them)"
  log "no ACTIVE instances"
else
  log "API not reachable — assuming the stack is already down"
fi
current_version=$(api GET /topology 2>/dev/null | jq -r '.gatewayVersion' 2>/dev/null || echo "?")
log "current version $current_version (the backup's version is in the snapshot names)"

# 1. down + wipe the two data volumes
log "step 1: docker compose down + remove ${PROJECT}_camunda ${PROJECT}_elastic"
docker compose down
docker volume rm -f "${PROJECT}_camunda" "${PROJECT}_elastic" >/dev/null

# 2. clean start seeds the templates
log "step 2: clean start (templates)"
docker compose up -d elasticsearch orchestration
wait_healthy elasticsearch 300; wait_healthy orchestration 300
sleep 10
templates=$(es_curl "$ES/_index_template" | jq -r '.index_templates[].name' | grep -cE 'operate|tasklist|camunda' || true)
log "$templates index templates seeded"
[ "${templates:-0}" -gt 0 ] || fail "no index templates after the clean start"
if [ "$PAUSE" = "--pause-after-seed" ]; then
  echo "PAUSED — Operate is empty at http://<stand>:8080/operate (fresh users from application.yaml). Press Enter to continue."; read -r _
fi

# 2b. the repository is cluster state — gone with the elastic volume; register + verify,
#     then make sure the set is really there before touching anything else
log "step 2b: snapshot repository"
ensure_repo
snaps=$(snapshots_of "$ID")
[ -n "$snaps" ] || fail "no snapshots for backup $ID in repository $REPO (expected camunda_webapps_${ID}_* in $BACKUP_ROOT/es)"
log "snapshots of set $ID:"; printf '%s\n' "$snaps" | sed 's/^/  /'

# 3. stop the writer, delete the indices (zero matches is fine on a re-run)
log "step 3: stop orchestration, delete indices"
docker compose stop orchestration
indices=$(es_curl "$ES/_cat/indices?h=index" | grep -E 'camunda|operate|tasklist|optimize|zeebe' || true)
[ -n "$indices" ] || log "no indices to delete"
for index in $indices; do
  printf '  delete %s → ' "$index"; es_curl -X DELETE "$ES/$index" | jq -c .
done

# 4. restore the snapshots of the set: the web-apps parts (and zeebe-record*) first, then
#    camunda_dated_<id> for the day-suffixed indices the parts did not bring back (an index
#    that already exists makes a restore fail, so the dated snapshot is filtered)
log "step 4: restore snapshots"
for snap in $(printf '%s\n' "$snaps" | grep -v '^camunda_dated_'); do
  printf '  %s → ' "$snap"
  es_curl -X POST "$ES/_snapshot/$REPO/$snap/_restore?wait_for_completion=true" | jq -c '.snapshot | {indices: (.indices|length), shards}'
done
dated_snap=$(printf '%s\n' "$snaps" | grep '^camunda_dated_' || true)
if [ -n "$dated_snap" ]; then
  existing=$(es_curl "$ES/_cat/indices?h=index" | sort)
  missing=$(es_curl "$ES/_snapshot/$REPO/$dated_snap" | jq -r '.snapshots[0].indices[]' | sort | comm -23 - <(printf '%s\n' "$existing") | paste -sd, -)
  if [ -n "$missing" ]; then
    printf '  %s (only indices absent after the parts: %s) → ' "$dated_snap" "$missing"
    es_curl -X POST "$ES/_snapshot/$REPO/$dated_snap/_restore?wait_for_completion=true" \
      -H 'Content-Type: application/json' -d "{\"indices\":\"$missing\",\"include_global_state\":false}" | jq -c '.snapshot | {indices: (.indices|length), shards}'
  else
    log "  $dated_snap: every day-suffixed index already came back with the parts — skipped"
  fi
fi

# 5. the seed start wrote raft data — the Zeebe data dir must be empty before bin/restore
log "step 5: remove ${PROJECT}_camunda (data dir must be empty)"
docker compose rm -sf orchestration >/dev/null
docker volume rm -f "${PROJECT}_camunda" >/dev/null
if docker volume ls -q | grep -qx "${PROJECT}_camunda"; then fail "volume ${PROJECT}_camunda still exists — data dir would not be empty"; fi
log "data dir empty (volume absent, recreated empty by the restore run)"

# 6. restore app — same image, same config (application.yaml bind mount)
log "step 6: bin/restore --backupId=$ID"
docker compose run --rm --no-deps -e SPRING_PROFILES_ACTIVE=restore \
  --entrypoint /usr/local/camunda/bin/restore orchestration "--backupId=$ID" 2>&1 | tee "/tmp/restore-$ID.log" | grep -E "Successfully restored|ERROR|Exception" || true
grep -q "Successfully restored broker from backup" "/tmp/restore-$ID.log" || fail "restore app did not report success — see /tmp/restore-$ID.log"

# 7. start everything, PostgreSQL, verify
log "step 7: start all"
docker compose up -d
wait_healthy orchestration 300
"$(dirname "$0")/pg-restore.sh" "$ID"
sleep 15
"$(dirname "$0")/verify-state.sh"
echo; echo "restore $ID complete — compare with the verify-state output taken before the backup"

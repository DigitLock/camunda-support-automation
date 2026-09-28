#!/usr/bin/env bash
# Backup retention (Phase 6.5, docs/runbooks/backup-restore.md "Retention"): list the backup
# sets on the stand with their parts, or delete one set completely through the official APIs.
#   tests/ops/delete-backup.sh --list                 # every set, one line each, missing parts visible
#   tests/ops/delete-backup.sh <backupId> --dry-run   # prints what would be removed, changes nothing
#   tests/ops/delete-backup.sh <backupId>             # removes the set, then prints the remaining sets
# A set = web-apps snapshots camunda_webapps_<id>_<ver>_part_n_of_m (+ camunda_zeebe_records_backup_<id>
# if ever taken) + our camunda_dated_<id> snapshot, the Zeebe partition backup <id>, and the
# pg dump camunda_support_<id>.dump. Deletion goes through
#   DELETE :9600/actuator/backupHistory/<id>   (8.9 web-apps backup API: sends the snapshot
#                                              deletions to Elasticsearch, which finishes them
#                                              asynchronously — polled here; 404 = no parts)
#   DELETE :9200/_snapshot/camunda/<snapshot>  (camunda_dated_* and zeebe_records: ours, ES API)
#   DELETE :9600/actuator/backupRuntime/<id>   (8.9 Zeebe backup API, 204)
#   rm of the one pg dump file.
# Never rm inside the es/ or zeebe/ backup directories. Refuses the newest set, refuses
# while any web-apps or Zeebe backup is IN_PROGRESS. An incomplete set (parts missing) is
# deletable: whatever exists is removed. Prints no secret; a deleted id cannot be reused
# (8.9 docs) — irrelevant with date +%s ids.
# The pg directory is owned by uid 70 (the postgres container user) and the dumps by root,
# so the deploy user cannot remove a dump (observed 2026-09-28). Deleting a set therefore
# runs as root (su -); the pre-flight below refuses BEFORE any DELETE when the dump exists
# and its directory is not writable, so a set is never half-deleted. --list and --dry-run
# work as any user.
. "$(dirname "$0")/_lib.sh"

usage() { echo "usage: $0 --list | <backupId> [--dry-run]" >&2; exit 2; }
MODE=delete; DRY=0; ID=""
case "${1:-}" in
  --list) MODE=list ;;
  "")     usage ;;
  *)      ID=$1; [[ "$ID" =~ ^[0-9]+$ ]] || usage; [ "${2:-}" = "--dry-run" ] && DRY=1; [ -n "${2:-}" ] && [ "$DRY" = 0 ] && usage ;;
esac

# HTTP status of a management call (mgmt returns bodies only): mgmt_code METHOD PATH
mgmt_code() { es_curl -o /dev/null -w '%{http_code}' -X "$1" "$MGMT$2"; }

# ---- discovery: three sources, joined by id ---------------------------------------------
snap_json()   { es_curl "$ES/_snapshot/$REPO/_all" | jq -c '[(.snapshots // [])[] | {snapshot, state}]'; }
zeebe_json()  { mgmt GET /actuator/backupRuntime | jq -c 'if type=="array" then [.[] | {backupId: (.backupId|tostring), state}] else [] end' 2>/dev/null || echo '[]'; }
webapps_json(){ mgmt GET /actuator/backupHistory | jq -c 'if type=="array" then [.[] | {backupId: (.backupId|tostring), state}] else [] end' 2>/dev/null || echo '[]'; }
pg_ids()      { ls "$BACKUP_ROOT/pg" 2>/dev/null | sed -E -n 's/^camunda_support_([0-9]+)\.dump$/\1/p'; }

# all ids known to any source, ascending
all_ids() {
  {
    printf '%s' "$SNAPS" | jq -r '.[].snapshot' | sed -E -n 's/^camunda_(webapps|zeebe_records_backup|dated)_([0-9]+)(_.*)?$/\2/p'
    printf '%s' "$ZEEBE" | jq -r '.[].backupId'
    printf '%s' "$WEBAPPS" | jq -r '.[].backupId'
    pg_ids
  } | grep -E '^[0-9]+$' | sort -n | uniq
}

# describe ID — one line: parts present / missing; sets $incomplete
describe() {
  local id=$1 parts total wstate dated zstate pg records line
  parts=$(printf '%s' "$SNAPS" | jq -r --arg id "$id" '[.[] | select(.snapshot | test("^camunda_webapps_" + $id + "_"))] | length')
  total=$(printf '%s' "$SNAPS" | jq -r --arg id "$id" '[.[] | select(.snapshot | test("^camunda_webapps_" + $id + "_")) | .snapshot | capture("_of_(?<m>[0-9]+)$").m | tonumber] | max // 0')
  wstate=$(printf '%s' "$WEBAPPS" | jq -r --arg id "$id" '[.[] | select(.backupId == $id) | .state] | first // empty')
  dated=$(printf '%s' "$SNAPS" | jq -r --arg id "$id" '[.[] | select(.snapshot == "camunda_dated_" + $id) | .state] | first // "-"')
  records=$(printf '%s' "$SNAPS" | jq -r --arg id "$id" '[.[] | select(.snapshot == "camunda_zeebe_records_backup_" + $id) | .state] | first // empty')
  zstate=$(printf '%s' "$ZEEBE" | jq -r --arg id "$id" '[.[] | select(.backupId == $id) | .state] | first // "-"')
  pg=$([ -f "$BACKUP_ROOT/pg/camunda_support_$id.dump" ] && echo yes || echo "-")
  incomplete=0
  { [ "$parts" = 0 ] || [ "$parts" != "$total" ] || [ "$zstate" != COMPLETED ] || [ "$pg" != yes ]; } && incomplete=1
  line=$(printf '%s  webapps %s/%s%s  dated %s  zeebe %s  pg %s' "$id" "$parts" "$total" "${wstate:+ ($wstate)}" "$dated" "$zstate" "$pg")
  [ -n "$records" ] && line="$line  zeebe-records $records"
  [ "$incomplete" = 1 ] && line="$line  INCOMPLETE"
  echo "  $line"
}

load()  { SNAPS=$(snap_json); ZEEBE=$(zeebe_json); WEBAPPS=$(webapps_json); }
list_sets() {
  local ids; ids=$(all_ids)
  [ -n "$ids" ] || { echo "  (no backup sets)"; return 0; }
  echo "  id          parts (webapps n/m, dated, zeebe, pg)"
  for i in $ids; do describe "$i"; done
}

load
if [ "$MODE" = list ]; then echo "backup sets:"; list_sets; exit 0; fi

# ---- refusals --------------------------------------------------------------------------
ids=$(all_ids); newest=$(printf '%s\n' "$ids" | tail -n1)
printf '%s\n' "$ids" | grep -qx "$ID" || fail "backup $ID: unknown to the repository, the Zeebe store and $BACKUP_ROOT/pg"
[ "$ID" != "$newest" ] || fail "backup $ID is the newest set — refused (keep at least the latest)"
busy=$(printf '%s %s' "$ZEEBE" "$WEBAPPS" | jq -rs '[.[][] | select(.state == "IN_PROGRESS") | .backupId] | unique | join(",")')
[ -z "$busy" ] || fail "a backup is IN_PROGRESS (id $busy) — nothing is deleted while a backup runs"

echo "set $ID before:"; describe "$ID"
pg_file="$BACKUP_ROOT/pg/camunda_support_$ID.dump"
if [ -f "$pg_file" ] && ! [ -w "$(dirname "$pg_file")" ]; then
  if [ "$DRY" = 1 ]; then
    echo "  would fail: $(dirname "$pg_file") is not writable by $(id -un) — run the deletion as root: su -, then the same command"
  else
    fail "$(dirname "$pg_file") is not writable by $(id -un) — the pg dump could not be removed after the API parts; run as root: su -, then the same command (nothing was deleted)"
  fi
fi
snaps_of_id=$(printf '%s' "$SNAPS" | jq -r --arg id "$ID" '.[] | .snapshot | select(test("^camunda_(webapps|zeebe_records_backup|dated)_" + $id + "(_|$)"))')
own_snaps=$(printf '%s\n' "$snaps_of_id" | grep -E "^camunda_(dated|zeebe_records_backup)_$ID$" || true)
has_webapps=$(printf '%s\n' "$snaps_of_id" | grep -c "^camunda_webapps_${ID}_" || true)
has_zeebe=$(printf '%s' "$ZEEBE" | jq -r --arg id "$ID" '[.[] | select(.backupId == $id)] | length')

# ---- plan / execute ----------------------------------------------------------------------
run() { # run DESCRIPTION COMMAND...
  local what=$1; shift
  if [ "$DRY" = 1 ]; then echo "  would: $what"; return 0; fi
  log "$what"; "$@"
}
del_webapps() { local st; st=$(mgmt_code DELETE "/actuator/backupHistory/$ID"); case "$st" in 204) ;; 404) log "  backupHistory: no parts (404)";; *) fail "DELETE backupHistory/$ID returned $st";; esac; }
del_snap()    { es_curl -X DELETE "$ES/_snapshot/$REPO/$1" | jq -c . | sed 's/^/  /'; }
del_zeebe()   { local st; st=$(mgmt_code DELETE "/actuator/backupRuntime/$ID"); [ "$st" = 204 ] || fail "DELETE backupRuntime/$ID returned $st"; }
del_pg()      { rm -f -- "$pg_file"; }

[ "${has_webapps:-0}" -gt 0 ] && run "DELETE $MGMT/actuator/backupHistory/$ID ($has_webapps web-apps snapshot(s))" del_webapps
for s in $own_snaps; do run "DELETE $ES/_snapshot/$REPO/$s" del_snap "$s"; done
[ "$has_zeebe" -gt 0 ] && run "DELETE $MGMT/actuator/backupRuntime/$ID" del_zeebe
[ -f "$pg_file" ] && run "rm $pg_file" del_pg

if [ "$DRY" = 1 ]; then echo "dry run — nothing changed"; exit 0; fi

# the web-apps deletion is asynchronous on the Elasticsearch side — wait until the repository
# no longer lists any snapshot of the id (bounded)
deadline=$((SECONDS + 120))
while :; do
  left=$(es_curl "$ES/_snapshot/$REPO/_all" | jq -r --arg id "$ID" '[(.snapshots // [])[] | .snapshot | select(test("_" + $id + "(_|$)"))] | length')
  [ "$left" = 0 ] && break
  [ "$SECONDS" -lt "$deadline" ] || fail "$left snapshot(s) of $ID still in the repository after 120 s — check Elasticsearch, then re-run"
  sleep 3
done
log "set $ID removed"
load
echo "remaining sets:"; list_sets

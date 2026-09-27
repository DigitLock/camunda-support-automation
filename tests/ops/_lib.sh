# Shared helpers for tests/ops/*.sh — sourced, not executed. Run on the stand host from
# infra/ (the scripts cd there). Credentials come from infra/.env and are never printed.
# The management port (9600) and Elasticsearch (9200) are not published: every call to
# them goes through curl inside the elasticsearch container (the orchestration image has
# no curl), which shares the compose network.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../infra"
[ -f .env ] || { echo "error: infra/.env not found — run on the stand host" >&2; exit 1; }
# shellcheck disable=SC1091
set -a; . ./.env; set +a

ES=http://localhost:9200
MGMT=http://orchestration:9600
API=http://localhost:8080/v2
REPO=camunda
BACKUP_ROOT=/srv/camunda-backups

log()  { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# curl inside the elasticsearch container: es_curl [curl args…] URL
es_curl() { docker compose exec -T elasticsearch curl -sS --max-time 60 "$@"; }
# management API of the orchestration cluster (no auth on 9600)
mgmt() { # mgmt METHOD PATH [JSON]
  local m=$1 p=$2 b=${3:-}
  if [ -n "$b" ]; then es_curl -X "$m" "$MGMT$p" -H 'Content-Type: application/json' -d "$b"
  else es_curl -X "$m" "$MGMT$p"; fi
}
# public REST API v2 from the host, admin credentials from .env
api() { # api METHOD PATH [JSON]
  local m=$1 p=$2 b=${3:-}
  if [ -n "$b" ]; then curl -sS --max-time 30 -u "admin:$CAMUNDA_ADMIN_PASSWORD" -X "$m" "$API$p" -H 'Content-Type: application/json' -d "$b"
  else curl -sS --max-time 30 -u "admin:$CAMUNDA_ADMIN_PASSWORD" -X "$m" "$API$p"; fi
}
project() { docker compose config --format json 2>/dev/null | jq -r '.name'; }

# poll_state GETTER LABEL [TIMEOUT_S] — GETTER prints a state; waits for COMPLETED, fails on FAILED
poll_state() {
  local getter=$1 label=$2 timeout=${3:-600} deadline state
  deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    state=$($getter 2>/dev/null || true)
    case "$state" in
      COMPLETED) log "$label: COMPLETED"; return 0 ;;
      FAILED|INCOMPLETE) fail "$label: $state" ;;
    esac
    log "$label: ${state:-…} — waiting"; sleep 5
  done
  fail "$label: not COMPLETED after ${timeout}s"
}

wait_healthy() { # wait_healthy SERVICE [TIMEOUT_S]
  local svc=$1 timeout=${2:-300} deadline h
  deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    h=$(docker compose ps --format '{{.Name}} {{.Health}}' 2>/dev/null | awk -v s="$svc" '$1==s{print $2}')
    [ "$h" = "healthy" ] && { log "$svc healthy"; return 0; }
    sleep 5
  done
  fail "$svc not healthy after ${timeout}s"
}

# --- exporter sync (mitigation A, docs/runbooks/backup-restore.md §6) --------------------------
EXPORTER_ID=${EXPORTER_ID:-camundaexporter}          # `exporter` label of the Camunda Exporter
EXPORTER_SYNC_TIMEOUT=${EXPORTER_SYNC_TIMEOUT:-120}  # seconds

# exporter_lag — one "PARTITION LAG" line per partition, from the Prometheus endpoint:
#   lag = max(0, zeebe_stream_processor_last_processed_position
#                − zeebe_exporter_last_updated_exported_position{exporter="$EXPORTER_ID"})
# The *updated* (acknowledged) position is the one persisted in the exporter state and the one
# a restore resumes from — that is the gap §6 describes. It normally runs AHEAD of the processed
# position by the follow-up events of the last command (stand, 2026-09-27: 981013 vs 981012,
# 981033 vs 981032), so the condition is updated >= processed, never equality. Empty output
# when a metric is absent.
exporter_lag() {
  mgmt GET /actuator/prometheus | awk -v ex="$EXPORTER_ID" '
    function lbl(s, k) { return match(s, k "=\"[^\"]*\"") ? substr(s, RSTART + length(k) + 2, RLENGTH - length(k) - 3) : "" }
    /^zeebe_stream_processor_last_processed_position\{/ { p[lbl($0, "partition")] = $2 }
    /^zeebe_exporter_last_updated_exported_position\{/ && lbl($0, "exporter") == ex { e[lbl($0, "partition")] = $2 }
    END { for (k in p) if (k in e) { d = p[k] - e[k]; if (d < 0) d = 0; printf "%s %.0f\n", k, d } }' | sort -n
}

# wait_exporter_sync [TIMEOUT_S] — block until lag == 0 on every partition (see exporter_lag),
# so that a restore re-exports only the records of the pause window. Polls every 2 s; on
# timeout prints the last lag per partition and fails (non-zero). Called by backup.sh before
# the soft-pause; reusable by restore-side tooling.
wait_exporter_sync() {
  local timeout=${1:-$EXPORTER_SYNC_TIMEOUT} start=$SECONDS lag
  while :; do
    lag=$(exporter_lag)
    [ -n "$lag" ] || fail "exporter sync: metrics not found on $MGMT/actuator/prometheus (expected zeebe_stream_processor_last_processed_position and zeebe_exporter_last_updated_exported_position{exporter=\"$EXPORTER_ID\"}); exporters seen: $(mgmt GET /actuator/prometheus | grep -o 'exporter="[^"]*"' | sort -u | paste -sd, -)"
    if printf '%s\n' "$lag" | awk '$2 != 0 { bad = 1 } END { exit bad }'; then
      log "exporter lag = 0 on all partitions (waited $((SECONDS - start))s)"; return 0
    fi
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      {
        echo "exporter still behind after ${timeout}s — last observed lag per partition:"
        printf '%s\n' "$lag" | awk '{ printf "  partition %s  lag %s\n", $1, $2 }'
        echo "hint: a stable, non-growing positive lag is usually job polling by the workers (each poll is a"
        echo "      processed record the exporter only acknowledges once it is otherwise up to date)."
        echo "      Either raise EXPORTER_SYNC_TIMEOUT, or stop the workers for the backup window:"
        echo "        docker compose stop worker-booking worker-llm-classifier && tests/ops/backup.sh && docker compose start worker-booking worker-llm-classifier"
      } >&2
      fail "exporter not in sync — backup aborted before soft-pause (EXPORTER_SYNC_TIMEOUT=$timeout, exporter $EXPORTER_ID)"
    fi
    sleep 2
  done
}

# ensure_repo — register the fs snapshot repository `camunda` if it is missing and verify it.
# Idempotent. Needed by backup.sh (first backup) AND by restore.sh after the elastic volume
# was wiped: the repository is cluster state, it disappears with the volume (observed
# 2026-09-27, first restore run).
ensure_repo() {
  if ! es_curl -f -o /dev/null "$ES/_snapshot/$REPO" 2>/dev/null; then
    log "registering snapshot repository $REPO"
    es_curl -X PUT "$ES/_snapshot/$REPO" -H 'Content-Type: application/json' \
      -d '{"type":"fs","settings":{"location":"/usr/share/elasticsearch/backup","compress":true}}' | jq -c .
  fi
  es_curl -X POST "$ES/_snapshot/$REPO/_verify" | jq -c '{verified_nodes: (.nodes | keys | length)}'
}

# snapshots_of ID — the snapshot names of a backup set, from the repository (works while the
# orchestration cluster is stopped); empty output when the set is not there
snapshots_of() {
  es_curl "$ES/_snapshot/$REPO/_all" | jq -r --arg id "$1" \
    '(.snapshots // [])[] | .snapshot | select(test("^camunda_(webapps|zeebe_records_backup|dated)_" + $id + "(_|$)"))'
}

# dated_patterns — "*_YYYY-MM-DD" for today and yesterday (UTC): the day-suffixed indices the
# archiver creates. Same-day data gap observed 2026-09-27 (docs/runbooks/backup-restore.md §6).
dated_patterns() {
  printf '*_%s,*_%s' "$(date -u +%F)" "$(date -u -d yesterday +%F 2>/dev/null || date -u -v-1d +%F)"
}

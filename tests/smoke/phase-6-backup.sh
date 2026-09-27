#!/bin/sh
# Phase 6.4 smoke — run on the VM after the deploy that introduces the backup stores:
#     tests/smoke/phase-6-backup.sh
# Checks: topology answers with credentials, the Zeebe backup store is configured
# (GET :9600/actuator/backupRuntime answers a JSON list — [] before the first backup), the
# web-apps backup endpoint answers, the snapshot repository `camunda` exists (registered by
# tests/ops/backup.sh; before that: 404 is reported, not failed), and the three host
# directories are writable by their containers. Run the writability checks BEFORE a
# --force-recreate with new backup keys: a wrong owner leaves partition 1 INACTIVE while the
# container stays healthy (observed 2026-09-27).
set -u
cd "$(dirname "$0")/../../infra"
fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
. ./.env
es() { docker compose exec -T elasticsearch curl -sS --max-time 20 "$@"; }

code=$(curl -sS -o /dev/null -w '%{http_code}' -u "admin:$CAMUNDA_ADMIN_PASSWORD" http://localhost:8080/v2/topology)
[ "$code" = "200" ] && ok "topology 200" || bad "topology (got $code)"

rt=$(es http://orchestration:9600/actuator/backupRuntime 2>/dev/null)
case "$rt" in
  \[*) ok "backupRuntime answers a list: $(printf '%s' "$rt" | cut -c1-60)" ;;
  *)   bad "backupRuntime (store not configured?): $(printf '%s' "$rt" | cut -c1-160)" ;;
esac
hist=$(es -o /dev/null -w '%{http_code}' http://orchestration:9600/actuator/backupHistory 2>/dev/null)
case "$hist" in
  200|404) ok "backupHistory reachable (HTTP $hist; 404 = repository not registered yet)" ;;
  *)       bad "backupHistory (HTTP $hist)" ;;
esac
repo=$(es -o /dev/null -w '%{http_code}' http://localhost:9200/_snapshot/camunda)
case "$repo" in
  200) ok "snapshot repository camunda registered" ;;
  404) echo "INFO snapshot repository not registered yet — tests/ops/backup.sh does it" ;;
  *)   bad "snapshot repository (HTTP $repo)" ;;
esac
es -o /dev/null -w '' http://localhost:9200/_cat/indices >/dev/null 2>&1 && ok "elasticsearch reachable"

docker compose exec -T elasticsearch sh -c 'touch /usr/share/elasticsearch/backup/.w && rm /usr/share/elasticsearch/backup/.w' 2>/dev/null && ok "es backup dir writable" || bad "es backup dir writable (chown 1000:1000 /srv/camunda-backups/es)"
docker compose exec -T orchestration bash -c 'touch /usr/local/camunda/backup/.w && rm /usr/local/camunda/backup/.w' 2>/dev/null && ok "zeebe backup dir writable" || bad "zeebe backup dir writable (chown 1001:1001 /srv/camunda-backups/zeebe — the camunda image runs as uid 1001)"
docker compose exec -T postgres sh -c 'touch /backups/.w && rm /backups/.w' 2>/dev/null && ok "pg backup dir writable" || bad "pg backup dir writable (chown 70:70 /srv/camunda-backups/pg)"

if [ "$fails" -eq 0 ]; then echo "smoke (phase 6.4): all checks passed"; exit 0; fi
echo "smoke (phase 6.4): $fails check(s) failed"; exit 1

#!/usr/bin/env bash
# Restore the audit database from the dump of a backup set (all three tables, --clean).
#   tests/ops/pg-restore.sh <backupId>
. "$(dirname "$0")/_lib.sh"
ID=${1:?usage: pg-restore.sh <backupId>}
[ -f "$BACKUP_ROOT/pg/camunda_support_$ID.dump" ] || fail "no dump for backup $ID in $BACKUP_ROOT/pg"
wait_healthy postgres 120
docker compose exec -T postgres sh -c 'pg_restore --clean --if-exists --no-owner -U "$POSTGRES_USER" -d "$POSTGRES_DB" "/backups/camunda_support_'"$ID"'.dump"'
log "pg_restore done"
docker compose exec -T postgres sh -c 'psql -q -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select '"'"'llm_audit '"'"'||count(*) from llm_audit union all select '"'"'classification_review '"'"'||count(*) from classification_review union all select '"'"'sla_escalation '"'"'||count(*) from sla_escalation"'

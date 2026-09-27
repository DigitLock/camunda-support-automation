#!/usr/bin/env bash
# pg_dump of the audit database (llm_audit, classification_review, sla_escalation) into the
# host bind mount /srv/camunda-backups/pg, named by the Camunda backup id so the sets pair up.
#   tests/ops/pg-backup.sh <backupId>
. "$(dirname "$0")/_lib.sh"
ID=${1:?usage: pg-backup.sh <backupId>}
docker compose exec -T postgres sh -c 'pg_dump -Fc -U "$POSTGRES_USER" "$POSTGRES_DB" -f "/backups/camunda_support_'"$ID"'.dump"'
ls -l "$BACKUP_ROOT/pg/camunda_support_$ID.dump"
docker compose exec -T postgres sh -c 'psql -q -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select '"'"'llm_audit '"'"'||count(*) from llm_audit union all select '"'"'classification_review '"'"'||count(*) from classification_review union all select '"'"'sla_escalation '"'"'||count(*) from sla_escalation"'

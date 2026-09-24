#!/bin/sh
# Phase 5 infrastructure smoke test — run on the VM:
#     tests/smoke/phase-5-infra.sh
# Checks: postgres healthy, both audit tables exist, the worker container is healthy,
# an INSERT/ROLLBACK round-trip works under the worker's credentials, and reports the
# current classify-audit row count (expected 7 after one e2e run — asserted by the
# Phase 5.1 acceptance, not here, because a job needs a process instance).
set -u

cd "$(dirname "$0")/../../infra"
fails=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1"; fails=$((fails + 1)); }

psql_c() { docker compose exec -T postgres psql -q -U "$1" -d "$2" -tAc "$3" 2>/dev/null; }

# credentials from infra/.env (compose reads the same file)
. ./.env

health=$(docker compose ps --format '{{.Name}} {{.Health}}' 2>/dev/null)
echo "$health" | grep -q "^postgres healthy$" && ok "postgres container healthy" || bad "postgres container healthy (got: $(echo "$health" | grep '^postgres' || echo missing))"
echo "$health" | grep -q "^worker-llm-classifier healthy$" && ok "worker-llm-classifier container healthy" || bad "worker-llm-classifier container healthy"

for table in llm_audit classification_review; do
  exists=$(psql_c "$POSTGRES_USER" "$POSTGRES_DB" "select to_regclass('public.$table') is not null")
  [ "$exists" = "t" ] && ok "table $table exists" || bad "table $table exists (got '$exists')"
done

roundtrip=$(psql_c "$POSTGRES_USER" "$POSTGRES_DB" \
  "begin; insert into llm_audit (ticket_id, job_type, model, prompt_version) values ('SMOKE','smoke','smoke','smoke'); rollback; select 'ok'" \
  | tail -n 1)
[ "$roundtrip" = "ok" ] && ok "llm_audit insert/rollback round-trip" || bad "llm_audit insert/rollback round-trip"

count=$(psql_c "$POSTGRES_USER" "$POSTGRES_DB" "select count(*) from llm_audit where job_type='classify'")
echo "INFO llm_audit classify rows: ${count:-unknown} (expect 7 after one e2e run)"

if [ "$fails" -eq 0 ]; then
  echo "smoke (phase 5): all checks passed"
  exit 0
fi
echo "smoke (phase 5): $fails check(s) failed"
exit 1

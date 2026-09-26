#!/bin/sh
# Phase 6 monitoring smoke test — run on the VM:
#     tests/smoke/phase-6-monitoring.sh
# Checks: prometheus and grafana containers healthy, the orchestration scrape target is up,
# the two alert rules are loaded, the stand dashboard is provisioned, and reports the current
# pending-incident count (0 on a quiet stand; > 0 while an incident scenario runs).
set -u

cd "$(dirname "$0")/../../infra"
fails=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1"; fails=$((fails + 1)); }

# credentials from infra/.env (compose reads the same file)
. ./.env

prom() { docker compose exec -T prometheus wget -qO- "http://localhost:9090$1" 2>/dev/null; }

health=$(docker compose ps --format '{{.Name}} {{.Health}}' 2>/dev/null)
for svc in prometheus grafana; do
  echo "$health" | grep -q "^$svc healthy$" && ok "$svc container healthy" || bad "$svc container healthy (got: $(echo "$health" | grep "^$svc" || echo missing))"
done

targets=$(prom /api/v1/targets)
echo "$targets" | grep -q '"job":"orchestration"[^}]*"health":"up"' \
  && ok "scrape target orchestration:9600 is up" \
  || bad "scrape target orchestration:9600 is up (got: $(echo "$targets" | grep -o '"lastError":"[^"]*"' | head -1))"

rules=$(prom /api/v1/rules)
for rule in CamundaIncidentsPending OrchestrationTargetDown; do
  echo "$rules" | grep -q "\"name\":\"$rule\"" && ok "alert rule $rule loaded" || bad "alert rule $rule loaded"
done

pending=$(prom '/api/v1/query?query=sum(zeebe_pending_incidents_total)' | sed -n 's/.*"value":\[[0-9.]*,"\([^"]*\)".*/\1/p')
echo "INFO pending incidents: ${pending:-unknown} (0 on a quiet stand)"

dash=$(docker compose exec -T grafana wget -qO- --header "Authorization: Basic $(printf 'admin:%s' "$GRAFANA_ADMIN_PASSWORD" | base64 | tr -d '\n')" \
  'http://localhost:3000/api/search?query=Camunda%20stand' 2>/dev/null)
echo "$dash" | grep -q '"uid":"camunda-stand"' && ok "dashboard camunda-stand provisioned" || bad "dashboard camunda-stand provisioned (got: ${dash:-empty})"

if [ "$fails" -eq 0 ]; then
  echo "smoke (phase 6 monitoring): all checks passed"
  exit 0
fi
echo "smoke (phase 6 monitoring): $fails check(s) failed"
exit 1

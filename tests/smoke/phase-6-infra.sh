#!/bin/sh
# Phase 6.1 infrastructure smoke test — two modes, one file (same layout as phase-4-infra.sh):
#
#  - host mode (run on the VM): booking-api fault toggle round-trip via the binary's own
#    operator flag (scratch image: no shell, no curl, port not published), the HTTP effect
#    checked from the `smoke` compose service (curlimages/curl, in-network), and the
#    booking worker's container env (RETRY_BACKOFF, BOOKING_API_URL) plus health:
#        tests/smoke/phase-6-infra.sh
#
#  - container mode (SMOKE_IN_CONTAINER=1, EXPECT=<code>): one curl against booking-api;
#    invoked by host mode through `docker compose run --entrypoint`.
set -u

fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

if [ "${SMOKE_IN_CONTAINER:-}" = "1" ]; then
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "http://booking-api:8080/bookings/BK-1001" 2>/dev/null || echo 000)
  [ "$code" = "${EXPECT:-200}" ] && ok "booking-api GET /bookings/BK-1001 -> $code" || bad "booking-api GET /bookings/BK-1001: expected ${EXPECT:-200}, got $code"
  [ "$fails" -eq 0 ] && exit 0 || exit 1
fi

cd "$(dirname "$0")/../../infra"

fault() { docker compose exec -T booking-api /app -fault "$1" 2>&1; }
in_container() { # in_container EXPECTED_CODE
  docker compose run --rm --no-deps -e SMOKE_IN_CONTAINER=1 -e EXPECT="$1" \
    --entrypoint "/bin/sh /smoke/phase-6-infra.sh" smoke
}
# never leave the fault on, whatever fails below
trap 'fault off >/dev/null 2>&1' EXIT

st=$(fault status)
echo "$st" | grep -q '"active":false' && ok "fault initially off ($st)" || bad "fault initially off (got: $st)"

st=$(fault on)
echo "$st" | grep -q '"active":true' && echo "$st" | grep -q '"status":503' && ok "fault on -> 503 ($st)" || bad "fault on (got: $st)"
in_container 503 || fails=$((fails + 1))

st=$(fault off)
echo "$st" | grep -q '"active":false' && ok "fault off ($st)" || bad "fault off (got: $st)"
in_container 200 || fails=$((fails + 1))

health=$(docker compose ps --format '{{.Name}} {{.Health}}' 2>/dev/null)
echo "$health" | grep -q "^booking-api healthy$" && ok "booking-api container healthy throughout" || bad "booking-api container healthy"
echo "$health" | grep -q "^worker-booking healthy$" && ok "worker-booking container healthy" || bad "worker-booking container healthy"

env=$(docker inspect worker-booking --format '{{join .Config.Env "\n"}}' 2>/dev/null)
for var in RETRY_BACKOFF BOOKING_API_URL; do
  echo "$env" | grep -q "^$var=" && ok "worker-booking env $var present ($(echo "$env" | grep "^$var=" ))" || bad "worker-booking env $var present"
done

if [ "$fails" -eq 0 ]; then
  echo "smoke (phase 6.1): all checks passed"
  exit 0
fi
echo "smoke (phase 6.1): $fails check(s) failed"
exit 1

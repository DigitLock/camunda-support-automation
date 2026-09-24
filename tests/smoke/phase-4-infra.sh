#!/bin/sh
# Phase 4 infrastructure smoke test. Two modes, one file:
#
#  - host mode (run on the VM): checks the Kafka topics via `docker compose exec`, then
#    re-runs itself inside the `smoke` compose service (curl image) for the HTTP checks:
#        tests/smoke/phase-4-infra.sh
#
#  - container mode (SMOKE_IN_CONTAINER=1, set by the compose service): curl checks
#    against booking-api and fx over the compose network. Can also be invoked directly:
#        docker compose run --rm --no-deps smoke
#    (the smoke service sits in its own "smoke" profile so `up` never starts it;
#    `compose run` activates the profile implicitly)
set -u

fails=0
expect_code() { # expect_code DESCRIPTION EXPECTED URL
  code=$(curl -sS -o /tmp/body -w '%{http_code}' --max-time 15 "$3" 2>/tmp/err || echo 000)
  if [ "$code" = "$2" ]; then
    echo "PASS $1"
  else
    echo "FAIL $1: expected HTTP $2, got $code $(cat /tmp/err 2>/dev/null)"
    fails=$((fails + 1))
  fi
}

if [ "${SMOKE_IN_CONTAINER:-}" = "1" ]; then
  expect_code "booking-api GET /bookings/BK-1001 -> 200" 200 "http://booking-api:8080/bookings/BK-1001"
  expect_code "booking-api GET /bookings/BK-FAIL-500 -> 500" 500 "http://booking-api:8080/bookings/BK-FAIL-500"
  expect_code "booking-api GET /bookings/BK-404 -> 404" 404 "http://booking-api:8080/bookings/BK-404"
  expect_code "fx GET /convert USD->EUR 100 -> 200" 200 "http://fx:8080/convert?from=USD&to=EUR&amount=100"
  if [ "$fails" -eq 0 ]; then
    converted=$(sed -n 's/.*"converted":\([0-9][0-9.]*\).*/\1/p' /tmp/body)
    if [ -n "$converted" ] && awk -v c="$converted" 'BEGIN { exit !(c > 0) }'; then
      echo "PASS fx converted > 0 ($converted)"
    else
      echo "FAIL fx converted > 0: got '$converted' (body: $(cat /tmp/body))"
      fails=$((fails + 1))
    fi
  fi
else
  cd "$(dirname "$0")/../../infra"
  topics=$(docker compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:29092 --list 2>/dev/null)
  for t in support.ticket.created support.ticket.resolved; do
    if echo "$topics" | grep -qx "$t"; then
      echo "PASS kafka topic $t exists"
    else
      echo "FAIL kafka topic $t missing"
      fails=$((fails + 1))
    fi
  done
  if ! docker compose run --rm --no-deps smoke; then
    fails=$((fails + 1))
  fi
fi

if [ "$fails" -eq 0 ]; then
  if [ "${SMOKE_IN_CONTAINER:-}" = "1" ]; then
    echo "smoke: all checks passed"
  else
    echo "smoke (host): all checks passed"
  fi
  exit 0
fi
echo "smoke: $fails check(s) failed"
exit 1

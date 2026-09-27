#!/usr/bin/env bash
# Patch-upgrade rehearsal on the lab stack (Phase 6.4, docs/ops/upgrade.md). Run on the
# stand host. The main stand must be STOPPED first (RAM): `docker compose stop` in infra/.
#   tests/ops/upgrade-lab.sh up                 # lab on the pinned (older) version
#   tests/ops/upgrade-lab.sh seed               # deploy the models, start 3 instances
#   tests/ops/upgrade-lab.sh state              # version, definitions, instances
#   tests/ops/upgrade-lab.sh upgrade 8.9.21 [8.9.12]   # re-pin, pull, up -d, verify
#   tests/ops/upgrade-lab.sh down               # stop the lab (data stays under /srv/camunda-lab)
set -euo pipefail
cd "$(dirname "$0")/../../infra"
ENVF=upgrade-lab/.env.lab
[ -f "$ENVF" ] || { echo "error: $ENVF missing — copy upgrade-lab/.env.lab.example and set the passwords" >&2; exit 1; }
set -a; . "./$ENVF"; set +a
LAB=(docker compose -p camunda-lab --env-file "$ENVF" -f docker-compose.yml -f upgrade-lab/lab.override.yml)
API=http://localhost:18080/v2
PROCESS_ID=support-request-v1
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
api() { local m=$1 p=$2 b=${3:-}; if [ -n "$b" ]; then curl -sS --max-time 30 -u "admin:$CAMUNDA_ADMIN_PASSWORD" -X "$m" "$API$p" -H 'Content-Type: application/json' -d "$b"; else curl -sS --max-time 30 -u "admin:$CAMUNDA_ADMIN_PASSWORD" -X "$m" "$API$p"; fi; }
wait_healthy() { local deadline=$((SECONDS + ${2:-300})) h; while [ "$SECONDS" -lt "$deadline" ]; do h=$("${LAB[@]}" ps --format '{{.Name}} {{.Health}}' | awk -v s="$1" '$1==s{print $2}'); [ "$h" = healthy ] && { log "$1 healthy"; return 0; }; sleep 5; done; echo "error: $1 not healthy" >&2; exit 1; }
main_running() { docker compose ps --status running -q 2>/dev/null | grep -c . || true; }

case "${1:-}" in
  up)
    [ "$(main_running)" = "0" ] || { echo "error: the main stand has running containers — docker compose stop first (RAM)" >&2; exit 1; }
    for d in camunda elastic backups/zeebe backups/es; do [ -d "/srv/camunda-lab/$d" ] || { echo "error: /srv/camunda-lab/$d missing (root: mkdir -p; chown 1001:1001 camunda backups/zeebe; chown 1000:1000 elastic backups/es)" >&2; exit 1; }; done
    log "lab up on camunda/camunda:$CAMUNDA_VERSION"
    "${LAB[@]}" up -d elasticsearch orchestration
    wait_healthy lab-elasticsearch 300; wait_healthy lab-orchestration 300
    api GET /topology | jq -c '{gatewayVersion, brokers: [(.brokers // [])[].version]}'   # brokers can be null right after healthy
    ;;
  seed)
    log "deploying models"
    curl -sS --max-time 60 -u "admin:$CAMUNDA_ADMIN_PASSWORD" -X POST "$API/deployments" \
      -F "resources=@../processes/support-request-v1.bpmn" -F "resources=@../decisions/routing-v1.dmn" \
      $(for f in ../forms/*.form; do printf -- '-F resources=@%s ' "$f"; done) \
      | jq -c '[.deployments[] | (.processDefinition // .decisionDefinition // .form // .decisionRequirements) | {id: (.processDefinitionId // .decisionDefinitionId // .formId // .decisionRequirementsId), version: (.version // .processDefinitionVersion)}]'   # a process reports processDefinitionVersion (8.9 v2)
    # the process has only a Kafka message start event: create instances with a start
    # instruction before classify-ticket; they wait there (no worker in the lab) — that is
    # the point: running instances that must survive the upgrade
    for n in 1 2 3; do
      api POST /process-instances "$(jq -cn --arg n "$n" '{processDefinitionId: "support-request-v1",
        startInstructions: [{elementId: "classify-ticket"}],
        variables: {ticketId: ("LAB-" + $n), customerId: ("C-LAB-" + $n), customerTier: "standard",
                    subject: "Lab ticket", body: "Upgrade rehearsal instance", language: "en",
                    bookingRef: null, bookingValue: null, currency: null, customerCurrency: "EUR", runId: "lab"}}')" \
        | jq -r '"instance \(.processInstanceKey) v\(.processDefinitionVersion)"'
    done
    ;;
  state)
    api GET /topology | jq -c '{gatewayVersion, brokers: [(.brokers // [])[] | {version, partitions: [.partitions[] | {partitionId, role, health}]}]}'   # health is per partition, not per broker (8.9 v2)
    sleep 3
    echo "definitions: $(api POST /process-definitions/search '{"filter":{"processDefinitionId":"support-request-v1"}}' | jq -c '[.items[] | .version]')"
    echo "instances ACTIVE: $(api POST /process-instances/search '{"filter":{"processDefinitionId":"support-request-v1","state":"ACTIVE"}}' | jq -c '[.items[] | .processInstanceKey]')"
    echo "jobs CREATED (ticket.classify): $(api POST /jobs/search '{"filter":{"type":"ticket.classify","state":"CREATED"},"page":{"limit":1}}' | jq -r '.page.totalItems')"
    ;;
  upgrade)
    NEW=${2:?usage: upgrade <camundaVersion> [<connectorsVersion>]}; NEWC=${3:-}
    log "re-pinning lab: CAMUNDA_VERSION $CAMUNDA_VERSION → $NEW${NEWC:+, CAMUNDA_CONNECTORS_VERSION → $NEWC}"
    sed -i "s|^CAMUNDA_VERSION=.*|CAMUNDA_VERSION=$NEW|" "$ENVF"
    [ -n "$NEWC" ] && sed -i "s|^CAMUNDA_CONNECTORS_VERSION=.*|CAMUNDA_CONNECTORS_VERSION=$NEWC|" "$ENVF"
    set -a; . "./$ENVF"; set +a
    "${LAB[@]}" pull orchestration
    "${LAB[@]}" up -d orchestration
    wait_healthy lab-orchestration 300
    sleep 5
    api GET /topology | jq -c '{gatewayVersion, brokers: [(.brokers // [])[].version]}'
    echo "instances ACTIVE after upgrade: $(api POST /process-instances/search '{"filter":{"processDefinitionId":"support-request-v1","state":"ACTIVE"}}' | jq -c '[.items[] | .processInstanceKey]')"
    # resumable: a worker can still activate the waiting jobs (short timeout, nothing completed)
    echo "activated jobs: $(api POST /jobs/activation '{"type":"ticket.classify","timeout":10000,"maxJobsToActivate":3,"requestTimeout":5000,"worker":"lab-probe"}' | jq -c '[.jobs[] | {jobKey, processInstanceKey}]')"
    ;;
  down)
    "${LAB[@]}" down
    log "lab down — data kept under /srv/camunda-lab (wipe as root when done); start the main stand: docker compose start"
    ;;
  *) echo "usage: $0 up | seed | state | upgrade <ver> [<connectorsVer>] | down" >&2; exit 2 ;;
esac

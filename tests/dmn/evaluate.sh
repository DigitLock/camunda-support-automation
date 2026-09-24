#!/usr/bin/env bash
# DMN test matrix for decisions/routing-v1.dmn (design docs/design/routing-v1.md §7).
# Evaluates decision `route-ticket` for every case in cases.json over the REST API v2
# and compares team / priority / slaHours / requiredChecks (as a set).
#
# A case also FAILs when failureMessage is set or when evaluatedDecisions does not list
# exactly 4 decisions — an unwired decision in the DRD resolves to null silently (D3-10).
#
# Env contract (same as tests/e2e): CAMUNDA_BASE_URL, CAMUNDA_USER, CAMUNDA_PASSWORD.
set -euo pipefail

cd "$(dirname "$0")"
CASES_FILE=cases.json
DECISION_ID=route-ticket
EXPECTED_DECISIONS=4

for var in CAMUNDA_BASE_URL CAMUNDA_USER CAMUNDA_PASSWORD; do
  if [ -z "${!var:-}" ]; then
    echo "error: $var is not set (same contract as tests/e2e and workers/stub)" >&2
    exit 1
  fi
done

BASE="${CAMUNDA_BASE_URL%/}/v2"

evaluate() { # evaluate JSON_INPUTS -> raw response
  curl -sS --fail-with-body -u "$CAMUNDA_USER:$CAMUNDA_PASSWORD" \
    -X POST "$BASE/decision-definitions/evaluation" \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg id "$DECISION_ID" --argjson vars "$1" \
          '{decisionDefinitionId: $id, variables: $vars}')"
}

fails=0
total=0
while IFS= read -r case_json; do
  total=$((total+1))
  id=$(echo "$case_json" | jq -r .id)
  inputs=$(echo "$case_json" | jq -c .inputs)
  response=$(evaluate "$inputs")

  failure=$(echo "$response" | jq -r '.failureMessage // empty')
  decisions=$(echo "$response" | jq '.evaluatedDecisions | length')
  # `output` is the decision result as a JSON string — unwrap it, then normalise:
  # requiredChecks as a sorted set, keys in stable order (-S)
  actual=$(echo "$response" | jq -cS '.output | fromjson
    | {team, priority, slaHours, requiredChecks: (.requiredChecks | sort)}' 2>/dev/null || echo '')
  expected=$(echo "$case_json" | jq -cS '.expected
    | {team, priority, slaHours, requiredChecks: (.requiredChecks | sort)}')

  if [ -n "$failure" ]; then
    echo "FAIL $id: failureMessage=$failure"; fails=$((fails+1))
  elif [ "$decisions" != "$EXPECTED_DECISIONS" ]; then
    echo "FAIL $id: evaluatedDecisions=$decisions, expected $EXPECTED_DECISIONS (unwired decision in the DRD?)"
    fails=$((fails+1))
  elif [ "$actual" != "$expected" ]; then
    echo "FAIL $id: got $actual, expected $expected"; fails=$((fails+1))
  else
    echo "PASS $id"
  fi
done < <(jq -c '.[]' "$CASES_FILE")

echo "$((total-fails))/$total cases passed"
[ "$fails" -eq 0 ] || exit 1

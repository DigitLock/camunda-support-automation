# DMN test matrix: routing-v1

`evaluate.sh` evaluates the deployed `route-ticket` decision (DRD `routing-v1`,
`docs/design/routing-v1.md` §7) for the 18 cases in `cases.json` (C18 is the Phase 4
currency demo: 1050 USD ≈ 920 `bookingValueEur` → `normal`, decision D3-7; since process
v5 the `sla-policy` input is `bookingValueEur`) via
`POST /v2/decision-definitions/evaluation` and compares `team`, `priority`, `slaHours`
and `requiredChecks` (as a set).

Environment contract is the same as `tests/e2e` and `workers/stub`:

```bash
export CAMUNDA_BASE_URL=http://localhost:8080   # or the stand's address
export CAMUNDA_USER=admin
export CAMUNDA_PASSWORD=...                     # from infra/.env on the stand

./evaluate.sh    # PASS/FAIL per case, "N/18 cases passed", exit 1 on any FAIL
```

A case FAILs when:

- the response carries a `failureMessage`;
- `evaluatedDecisions` does not list exactly 4 decisions — a decision left unwired in the
  DRD resolves to `null` silently instead of failing, so only this count catches it (D3-10);
- the four output fields do not match `expected`.

Each run is visible in Operate → Decisions as standalone evaluations (one per decision in
the DRD) with Process Instance Key = -1 — they come from the API, not from a process.

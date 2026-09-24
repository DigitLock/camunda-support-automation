# Routing v1 — DMN + FEEL design

Phase 3. Replaces the `ticket.route` job worker with a DMN decision evaluated by a business rule task. The stub worker keeps `ticket.classify`, `ticket.notify` and the three branch job types; routing logic lives only in `decisions/routing-v1.dmn`.

Related: `process-v1.md` (§5 variables, §8 tickets), `docs/backlog.md`.

## 1. Scope

In:
- DRD `routing-v1` with four decisions (§3).
- `route-ticket` in `support-request-v1.bpmn` becomes a business rule task → process version 4.
- FEEL in output mappings, including one date expression (`slaDeadline`).
- `ticket.route` handler and `intent → team` rules removed from the stub.
- Ticket T-1006 added; DMN test matrix in `tests/dmn/`.

Out (backlog):
- Consuming `requiredChecks` in branches / notification template (Phase 4–5).
- Currency-aware `bookingValue` threshold (Phase 4, Currency Rate Service).
- Changing any SLA value — Phase 3 keeps `slaHours` 4 / 24 exactly as the stub produced them.

## 2. Inputs and outputs

Inputs (process variables at `route-ticket`):

| Variable | Type | Values / notes |
|---|---|---|
| `intent` | string | `change_booking`, `cancel_refund`, `question`, `other` (from `ticket.classify`) |
| `sentiment` | string | as defined in `process-v1.md` §5 (`negative` is the only value the rules test) |
| `customerTier` | string | `premium` or `standard`, from the start message |
| `bookingValue` | number or `null` | from the start message; **must always be present** (`null` allowed) — a missing variable fails the FEEL input expression with an incident |

*Since Phase 4.3 (process v5+, DMN v3) the monetary input of the decision tables is
`bookingValueEur`, produced by the process (`convert-booking-value`, `process-v1.md` §10);
`null` when the ticket has no booking. The table above describes the original Phase 3 wiring
(as of Phase 3).*

Outputs (written by output mappings, §4):

| Variable | Type | Source |
|---|---|---|
| `team` | string | `routing.team` |
| `priority` | string | `routing.priority` |
| `slaHours` | number | `routing.slaHours` |
| `slaDeadline` | date-time | `now() + duration("PT" + string(routing.slaHours) + "H")` |
| `requiredChecks` | list of string | `routing.requiredChecks` (may be empty) |

## 3. DRD `routing-v1`

```
route-team ──┐
sla-policy ──┼──► route-ticket  (called from BPMN, result variable `routing`)
required-checks ┘
```

File: `decisions/routing-v1.dmn`. Decision names equal their IDs; because the IDs contain
hyphens, FEEL references them in backticks: `` `route-team` ``, `` `sla-policy`.priority ``.

### 3.1 `route-team` — decision table, hit policy FIRST

| # | intent | → team |
|---|---|---|
| 1 | `"change_booking"` | `"bookings"` |
| 2 | `"cancel_refund"` | `"refunds"` |
| 3 | `"question"` | `"support"` |
| 4 | – | `"escalation"` |

Row 4 covers `other` and any unexpected intent value.

### 3.2 `sla-policy` — decision table, hit policy FIRST

Inputs: `customerTier`, `sentiment`, `bookingValueEur` (named `bookingValue` until DMN v3). Rules are ordered: the first escalation condition that matches wins; the last row is the default.

| # | customerTier | sentiment | bookingValueEur | → priority | slaHours |
|---|---|---|---|---|---|
| 1 | `"premium"` | – | – | `"high"` | 4 |
| 2 | – | `"negative"` | – | `"high"` | 4 |
| 3 | – | – | `> 1000` | `"high"` | 4 |
| 4 | – | – | – | `"normal"` | 24 |

`bookingValueEur = null` never matches row 3 (comparison with null is not true). The threshold is in EUR since Phase 4.3 (see D3-7, closed).

### 3.3 `required-checks` — decision table, hit policy COLLECT

Single output `check` (string); the result is the list of all matching rows, in rule order.

| # | intent | customerTier | bookingValueEur | → check |
|---|---|---|---|---|
| 1 | `"change_booking"` | – | – | `"availability"` |
| 2 | `"cancel_refund"` | – | – | `"refund-policy"` |
| 3 | `"cancel_refund"` | – | `> 1000` | `"manual-approval"` |
| 4 | – | `"premium"` | – | `"vip-handling"` |

### 3.4 `route-ticket` — literal expression

Required decisions: `route-team`, `sla-policy`, `required-checks`. Expression as in the
current model:

```feel
{
  team: `route-team`,
  priority: `sla-policy`.priority,
  slaHours: `sla-policy`.slaHours,
  requiredChecks: if `required-checks` = null then [] else `required-checks`
}
```

The `null` guard exists because COLLECT returns `null`, not `[]`, when no rule matches (D3-9).

Evaluating `route-ticket` evaluates the three required decisions; Operate → Decisions shows all four with the rules that matched.

## 4. BPMN changes (`support-request-v1.bpmn` → v4)

`route-ticket`: service task → **business rule task**.
- Implementation: DMN decision, called decision ID `route-ticket`, binding *latest*.
- Result variable: `routing`.
- Output mappings:

| Source (FEEL) | Target |
|---|---|
| `routing.team` | `team` |
| `routing.priority` | `priority` |
| `routing.slaHours` | `slaHours` |
| `routing.requiredChecks` | `requiredChecks` |
| `now() + duration("PT" + string(routing.slaHours) + "H")` | `slaDeadline` |

Everything downstream (`gw-needs-review`, `gw-intent`, branch tasks, `notify-customer`) is unchanged. Deploy DMN and BPMN together from Modeler (*Include additional files*), or DMN first — the business rule task binds by decision ID at runtime, so the order only matters for the first instance.

## 5. Stub worker changes

- Remove `ticket.route` handler from `handlers.py` and its registration in the worker.
- Remove `intent → team` and priority rules from `rules.py`.
- Leave `ticket.classify` and `ticket.notify` rules untouched. The `resolution` / `notificationTemplate` output of branch tasks does not depend on routing outputs.
- README and `docs/design/process-v1.md` §7: note that routing moved to DMN as of Phase 3.

## 6. Tickets and e2e

- T-1001 … T-1005: paths and expected `team / priority / slaHours` unchanged. **Pre-check:** if any `standard` ticket has `bookingValue > 1000`, its expected priority would flip to `high` — lower the value in `tickets.json` rather than change the expectation.
- **T-1006** (new): `intent = question`, `customerTier = standard`, `sentiment = negative`, `bookingValue = null`. Expected: `support / high / 4`, `requiredChecks = []`, path `answer-question` → `notify-customer` → `end-resolved`. This is the only ticket where `high` comes from sentiment alone.
- `send-tickets.sh --check` additionally asserts `team`, `priority`, `slaHours`, `requiredChecks` (as a set) and that `slaDeadline` is a non-empty string; the deadline's serialization format is fixed by D3-11.

Every ticket must carry `bookingValue` in the message payload (`null` for question/other tickets) — see §2.

## 7. DMN test matrix (`tests/dmn/`)

Acceptance requires ≥ 15 cases, all passing. Files:
- `tests/dmn/cases.json` — array of `{ id, inputs: {intent, customerTier, sentiment, bookingValueEur}, expected: {team, priority, slaHours, requiredChecks} }` (18 cases since Phase 4.3; both decision tables read `bookingValueEur`, DMN v3).
- `tests/dmn/evaluate.sh` — for each case calls `POST /v2/decision-definitions/evaluation` (decision definition ID `route-ticket`, variables = inputs). The response carries the decision result in `output` as a JSON string, and the matched rules in `evaluatedDecisions[].matchedRules[].ruleIndex`. The script parses `output`, compares it with `expected` (`requiredChecks` compared as sets), prints PASS/FAIL per case and a summary. Uses the same `CAMUNDA_BASE_URL / CAMUNDA_USER / CAMUNDA_PASSWORD` as the e2e script.

| ID | intent | tier | sentiment | bookingValueEur | team | priority | sla | requiredChecks |
|---|---|---|---|---|---|---|---|---|
| C01 | change_booking | standard | neutral | 500 | bookings | normal | 24 | availability |
| C02 | change_booking | premium | neutral | 500 | bookings | high | 4 | availability, vip-handling |
| C03 | change_booking | standard | negative | 500 | bookings | high | 4 | availability |
| C04 | change_booking | standard | neutral | 1500 | bookings | high | 4 | availability |
| C05 | cancel_refund | standard | neutral | 800 | refunds | normal | 24 | refund-policy |
| C06 | cancel_refund | standard | neutral | 2500 | refunds | high | 4 | refund-policy, manual-approval |
| C07 | cancel_refund | premium | positive | 300 | refunds | high | 4 | refund-policy, vip-handling |
| C08 | cancel_refund | standard | negative | 1200 | refunds | high | 4 | refund-policy, manual-approval |
| C09 | question | standard | positive | null | support | normal | 24 | – |
| C10 | question | standard | negative | null | support | high | 4 | – |
| C11 | question | premium | neutral | null | support | high | 4 | vip-handling |
| C12 | other | standard | neutral | null | escalation | normal | 24 | – |
| C13 | other | premium | negative | 5000 | escalation | high | 4 | vip-handling |
| C14 | change_booking | standard | neutral | 1000 | bookings | normal | 24 | availability |
| C15 | cancel_refund | standard | neutral | 1000.01 | refunds | high | 4 | refund-policy, manual-approval |
| C16 | question | standard | neutral | 50 | support | normal | 24 | – |
| C17 | unknown_intent | standard | neutral | null | escalation | normal | 24 | – |
| C18 | change_booking | standard | neutral | 920 | bookings | normal | 24 | availability |

C10 = T-1006. C14/C15 are the threshold boundary. C17 exercises the default row of `route-team`. C18 (added in Phase 4.3) is the D3-7 currency demo: 1050 USD converts to ≈ 920 EUR, below the threshold → `normal`.

## 8. Acceptance

- [x] `decisions/routing-v1.dmn` deployed; Operate → Decisions lists `route-ticket`, `route-team`, `sla-policy`, `required-checks`.
- [x] Process `support-request-v1` at version 4 with `route-ticket` as a business rule task.
- [x] `tests/dmn/evaluate.sh` — 17/17 PASS (as of Phase 3; 18/18 since Phase 4.3, C18 added).
- [x] `tests/e2e/send-tickets.sh` — 6/6 PASS in default and `--manual-user-tasks` modes (run `20260923T210154Z`, verified via `--check`), expectations for T-1001…T-1005 unchanged.
- [x] Stub worker has no `ticket.route` handler; `grep -rn 'ticket.route' workers/` is empty.
- [x] Screenshots in `docs/assets/phase-3/`: `modeler-drd.png`, `modeler-route-team.png`, `modeler-sla-policy.png`, `modeler-required-checks.png`, `modeler-route-ticket.png`, `modeler-bpmn-business-rule-task.png`, `operate-decision-evaluation.png` (T-1006: `sla-policy` matched rule 2, "Upset customer"), `operate-decision-evaluation-default.png` (T-1003: default rule 4), `operate-route-ticket-result.png` (local `routing` variable on the `route-ticket` task, T-1005), `operate-instance-v4.png` (T-1006, all process variables).
- [x] `docs/ops/install.md` updated with anything that broke; README status line updated.

## 9. Decisions

| ID | Decision | Rationale |
|---|---|---|
| D3-1 | DRD of three tables + literal expression instead of one FIRST table | A single FIRST table needs 16 rows (4 intents × 4 priority cases) because FIRST returns one row and `team` depends on `intent`; splitting keeps each table readable and shows required-decision wiring in Operate |
| D3-2 | `slaHours` for `question` stays 24 | Phase goal is "same logic, different place"; changing values would blur the acceptance |
| D3-3 | `sentiment = "negative"` → `high` | The one rule that did not exist in the stub; demonstrates a rule change without a code change. Visible only via T-1006 |
| D3-4 | `ticket.route` removed from the stub in the same commit | Dead code in a portfolio repo reads worse than a clean diff |
| D3-5 | `slaDeadline` computed in the output mapping, not in DMN | Keeps the decision pure and re-evaluable; the date expression is required by the Phase 3 scope |
| D3-6 | `requiredChecks` exposed as a variable but not consumed yet | Consumers arrive with real integrations (Phase 4) and the notification template (Phase 5) |
| D3-7 | `bookingValue > 1000` ignores `currency` — **closed in Phase 4.3**: the process converts to EUR (`convert-booking-value`) and both tables read `bookingValueEur` | v1 assumed a single settlement currency; the FX gateway closed the hook |
| D3-8 | `route-team` uses FIRST with a catch-all row rather than UNIQUE | Unexpected intent values route to escalation instead of producing `null` and an incident |
| D3-9 | `route-ticket` guards the COLLECT result: `if ... = null then [] else ...` | COLLECT with no matching rule returns `null`, not `[]`; without the guard `requiredChecks` would be `null` for tickets with no checks |
| D3-10 | Decision wiring is asserted only by tests that compare all outputs | A decision left unwired in the DRD does not fail evaluation — its FEEL name silently resolves to `null`; nothing in deployment or Operate flags it |
| D3-11 | `slaDeadline` is stored as serialized by the engine: `"2026-09-24T20:37:41.585Z[GMT]"` | FEEL `now()` yields a zoned date-time with a zone id — not plain ISO 8601; Python's `fromisoformat` cannot parse it. Left as is until the first consumer (Phase 5), which will normalise it |

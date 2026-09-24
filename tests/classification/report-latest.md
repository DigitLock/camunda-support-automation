# Classification report (latest)

Prompt: `classify_v2` · threshold: 0.8 · tickets: 40 (full set) · runs: 3

- **Intent accuracy: 100.0%** (35/35 non-ambiguous)
- Silent errors (wrong intent, not reviewed): **0**
- Ambiguous routed to review: 5/5
- Sentiment accuracy: 97.5%
- Language accuracy: 100.0%
- Review rate: 15.0% · fallbacks: 0

## Intent confusion (expected → predicted)

| expected \ predicted | change_booking | cancel_refund | question | other |
|---|---|---|---|---|
| change_booking | 11 | 0 | 0 | 0 |
| cancel_refund | 0 | 10 | 0 | 0 |
| question | 0 | 0 | 10 | 0 |
| other | 0 | 0 | 0 | 4 |

## Threshold sweep

| threshold | auto-routed accuracy | review rate |
|---|---|---|
| 0.6 | 100.0% | 10.0% |
| 0.7 | 100.0% | 12.5% |
| 0.8 | 100.0% | 15.0% |
| 0.9 | 100.0% | 20.0% |

## Stability: 39/40 tickets identical across 3 runs

## Tokens and cost (last run)

- input 45387 (cache write 0, cache read 0), output 2205
- estimated cost: $0.0564 (haiku-4-5 prices as of 2026-09, cache-read-aware)

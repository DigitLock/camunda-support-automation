# Classification report (latest)

Prompt: `classify_v1` · threshold: 0.8 · tickets: 30 (full set) · runs: 3

- **Intent accuracy: 100.0%** (25/25 non-ambiguous)
- Silent errors (wrong intent, not reviewed): **0**
- Ambiguous routed to review: 5/5
- Sentiment accuracy: 100.0%
- Language accuracy: 100.0%
- Review rate: 20.0% · fallbacks: 0

## Intent confusion (expected → predicted)

| expected \ predicted | change_booking | cancel_refund | question | other |
|---|---|---|---|---|
| change_booking | 7 | 0 | 0 | 0 |
| cancel_refund | 0 | 6 | 0 | 0 |
| question | 0 | 0 | 8 | 0 |
| other | 0 | 0 | 0 | 4 |

## Threshold sweep

| threshold | auto-routed accuracy | review rate |
|---|---|---|
| 0.6 | 100.0% | 13.3% |
| 0.7 | 100.0% | 16.7% |
| 0.8 | 100.0% | 20.0% |
| 0.9 | 100.0% | 20.0% |

## Stability: 28/30 tickets identical across 3 runs

## Tokens and cost (last run)

- input 31057 (cache write 0, cache read 0), output 1902
- estimated cost: $0.0406 (haiku-4-5 prices as of 2026-09, cache-read-aware)

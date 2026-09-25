# Prompts

Versioned system prompts loaded by the workers at runtime, plus the knowledge base for
answers. The active version of each prompt is selected by an environment variable:

| File | Job type | Selected by | Since |
|---|---|---|---|
| `classify_v<N>.md` | `ticket.classify` | `CLASSIFY_PROMPT_VERSION` (current `classify_v2`) | 5.2 |
| `answer_v<N>.md` | `ticket.answer` | `ANSWER_PROMPT_VERSION` (current `answer_v1`) | 5.4 |
| `notify_v<N>.md` | `ticket.notify` | `NOTIFY_PROMPT_VERSION` (current `notify_v1`) | 5.4 |
| `kb_tourism.md` | `ticket.answer` (appended to the answer system prompt, D5-11) | fixed name | 5.4 |

The KB is reference data, not a prompt: it is edited in place, sections keep their ids
(`## KB-01 …`) and every answer records the ids it used (`answerKbIds`, audit output).
Removing or renumbering a section is a prompt-level change — bump `answer_v<N>` with it.

**Versioning rule: a prompt change is a new file with a new version, never an edit in
place.** Every classification is audited with its `prompt_version`, so an edited file
would silently break the audit trail. The procedure for any change:

1. copy the current file to `classify_v<N+1>.md`, edit the copy;
2. archive the outgoing calibration record:
   `mv tests/classification/report-latest.md tests/classification/report-classify_v<N>.md`;
3. set `CLASSIFY_PROMPT_VERSION=classify_v<N+1>` (compose default + `.env.example`s);
4. re-run `tests/classification/report.sh` and commit the new `report-latest.md`
   together with the new prompt file.

Versions so far: `classify_v1` (initial; calibration archived as
`report-classify_v1.md`), `classify_v2` (current: confidence rubric — ≥ 0.9 only for
explicit requests, 0.6–0.8 for inferred intent, < 0.6 for ambiguity — and a one-sentence
≤ 20-word rationale cap; both prompted by the v1 run: flat 0.95 confidences and a
rationale that overflowed 200 characters). `answer_v1` / `notify_v1` (5.4, initial;
generation record `tests/generation/report-answer_v1.md`). The same procedure applies to
the generation prompts with `tests/generation/report.sh`.

In containers the directory is mounted read-only at `/app/prompts`
(`infra/docker-compose.yml`); the venv dev run finds it relative to the repo.

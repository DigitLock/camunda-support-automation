# Traceability

Maps each capability this project demonstrates to the files that prove it. The evidence column is
filled in as the files appear; a dash means the phase has not produced them yet.

| Capability | Evidence |
|------------|----------|
| BPMN/DMN/FEEL design | — |
| Process versioning and instance migration | — |
| LLM classification with guardrails | `docs/design/llm-guardrails.md` (overview), `docs/design/llm-classifier-v1.md`, `workers/llm-classifier/`, `tests/classification/report-latest.md`, `tests/generation/report-answer_v1.md`, `docs/assets/phase-5/` |
| Prompt versioning | `prompts/README.md`, `prompts/classify_v1.md` → `classify_v2.md` with `tests/classification/report-classify_v1.md` archived, `CLASSIFY_/ANSWER_/NOTIFY_PROMPT_VERSION` in `infra/docker-compose.yml` |
| Call-flow modelling in BPMN | — |
| Incident handling in Operate | — |
| REST/JSON/Kafka integrations | — |
| Self-managed operations (install, monitoring, backup, upgrade) | `docs/ops/install.md`, `infra/docker-compose.yml`, `infra/config/orchestration/application.yaml`, `docs/assets/phase-1/operate-smoke.png` |
| SQL process analytics | — |

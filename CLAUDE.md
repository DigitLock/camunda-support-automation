# CLAUDE.md

Working rules for Claude Code in this repository.

## Project

Customer support automation on **Camunda 8.9 Self-Managed**: BPMN/DMN/FEEL process, LLM ticket
classifier with guardrails, REST and Kafka integrations, and an operations layer (incidents,
instance migration, backup, upgrade, monitoring). Single-node Docker Compose on a dedicated VM.
Decisions are recorded in `docs/adr/` — read them before proposing changes.

This is a **public portfolio repository**. Never reference employers, job applications,
private context, internal IPs or hostnames.

## Hard rules

1. **Never commit, push, tag, amend, reset or rebase.** The owner reviews every change and
   commits personally. Finish work by listing changed files and stopping.
2. **No secrets in tracked files.** Secrets live in `.env` (git-ignored). Keep `.env.example`
   in sync with every new variable, with placeholder values only.
3. **All artifacts are in English**: code, comments, docs, diagrams, commit-ready summaries.
4. **Docs are part of the change.** A change is not done until the relevant file under `docs/`
   is updated. Anything that breaks during installation goes into `docs/ops/install.md`
   immediately (symptom → cause → fix), not later.
5. **Phases are sequential** (see README). Do not start the next phase or add scope that is not
   in the current phase. Park ideas in `docs/backlog.md`.
6. **Pinned versions only.** No `latest` tags. Image tag and digest come from `.env`.
7. **Never create or edit .bpmn, .dmn or .form files.** The owner models them in Camunda
   Modeler; you may read them and reference element IDs.

## Camunda specifics (8.9)

- Use the **8.9 documentation** only. Property names changed between 8.8 and 8.9 (unified
  configuration) — do not guess property or environment variable names; verify them.
- One unified image: `camunda/camunda` (Orchestration Cluster = Zeebe + Operate + Tasklist +
  Identity). The separate `camunda/zeebe`, `camunda/operate`, `camunda/tasklist` images are gone.
- Clients talk to the **Orchestration Cluster REST API (v2)** only. No gRPC, no `zbctl`,
  no community Go client. The gateway gRPC port is not published.
- API is protected: Basic auth, authorizations enabled, dedicated users per worker.
- Secondary storage is Elasticsearch. Optimize, Keycloak and Web Modeler are out of scope.

## Languages

- `workers/llm-classifier/` — Python, official `camunda-orchestration-sdk`.
- Integration workers, mock Booking API, Kafka bridge — Go, using the thin REST client in
  `workers/internal/camunda`.

## Working loop

Plan → implement → run the phase acceptance check → update docs → stop and report
(what changed, what failed, what is left). Keep diffs small and reviewable.

## Style

Concise, natural-sounding documentation. Diagrams as code (Mermaid or PlantUML) next to the text
they explain. No filler sections, no "TODO" links in committed docs.

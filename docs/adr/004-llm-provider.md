# ADR-004: LLM provider for ticket classification

- **Status:** Accepted
- **Date:** 2026-09-21
- **Amended 2026-09-24 (Phase 5.0):** models pinned as aliases — `claude-haiku-4-5` for
  classification, `claude-sonnet-5` for customer-facing generation (D5-1,
  `docs/design/llm-classifier-v1.md`); the exact model id of every call is recorded in the
  audit table from the API response. Ollama definitively rejected: no local models on the
  homelab (owner decision); the provider abstraction stays, so a second provider remains a
  configuration change.

## Context

The classifier assigns intent, sentiment and language to support tickets in Russian and English.
It is a short-input, structured-output task run a few hundred times during testing. No models are
hosted locally.

## Decision

- **Anthropic Claude API**, small/fast model tier, temperature 0.
- Output is structured JSON validated against a JSON Schema on our side; invalid or
  low-confidence results fall back to keyword-based DMN routing and a human review task.
- Prompts are versioned files under `prompts/` with a labelled test set; every decision is
  written to the PostgreSQL audit table with model and prompt version.
- The provider sits behind a thin interface. A second provider configuration (OpenAI) is optional
  and only added if Phase 5 leaves time.
- The API key is supplied through the environment only.

## Consequences

- Classification depends on an external API: timeouts and provider errors must end in the
  fallback path, never in a stuck process instance.
- Test runs cost money, though little at this volume.

## Alternatives considered

- **Self-hosted model (Ollama)** — no API cost, but needs local hardware and operations that are
  outside this project.
- **OpenAI as primary** — viable; kept as the optional second configuration.

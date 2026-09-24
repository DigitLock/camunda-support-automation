"""LLM provider (design D5-1, D5-6).

The provider returns raw model output plus usage metadata; parsing, validation and
policy live in guardrails.py / classifier.py. Provider-neutral surface so a second
provider stays a configuration change (ADR-004).

Contract notes:
- `LLMResponse.model` is the exact model id from the API response (`response.model`),
  never the alias from the environment — the audit records what actually answered.
- `tokens_in` is the full input (regular + cache creation + cache read); the cache
  split is carried separately for the audit output and the cost report.
"""

import time
from dataclasses import dataclass
from typing import Protocol

import anthropic


@dataclass
class LLMResponse:
    text: str
    model: str                 # exact id from the API response, not the env alias
    tokens_in: int             # input_tokens + cache_creation + cache_read
    tokens_out: int
    cache_creation_tokens: int
    cache_read_tokens: int
    latency_ms: int
    block_types: list          # content block types, for invalid-output diagnostics


class LLMProvider(Protocol):
    def complete(self, user_message: str) -> LLMResponse:
        """One completion against the configured model. Raises on transport/API
        errors — the caller owns retry and fallback policy (D5-2, D5-7)."""
        ...


class ClaudeProvider:
    """Anthropic Claude via the official SDK.

    - Structured output: when `output_schema` is given it is passed as
      output_config.format (json_schema) — GA for claude-haiku-4-5 — so the API
      constrains the answer shape; jsonschema validation in guardrails.py stays as the
      second line of defence.
    - System prompt carries cache_control ephemeral. Note: the minimum cacheable prefix
      for haiku-4-5 is 4096 tokens; the classify prompt is well below that, so cache
      write/read stay 0 until the prompt grows — the marker is harmless and stays.
    """

    def __init__(self, api_key: str, model: str, system_prompt: str,
                 timeout: float = 30.0, max_retries: int = 2, max_tokens: int = 300,
                 output_schema: dict | None = None):
        self._client = anthropic.Anthropic(
            api_key=api_key, timeout=timeout, max_retries=max_retries
        )
        self._model = model
        self._system = [
            {"type": "text", "text": system_prompt, "cache_control": {"type": "ephemeral"}}
        ]
        self._max_tokens = max_tokens
        self._extra = {}
        if output_schema is not None:
            self._extra["output_config"] = {
                "format": {"type": "json_schema", "schema": output_schema}
            }

    def complete(self, user_message: str) -> LLMResponse:
        started = time.monotonic()
        # No temperature: anthropic 1.8.0 removed sampling parameters from
        # messages.create for current models. Determinism-by-request is gone —
        # output discipline comes from the schema-constrained output + validation (D5-2).
        response = self._client.messages.create(
            model=self._model,
            max_tokens=self._max_tokens,
            system=self._system,
            messages=[{"role": "user", "content": user_message}],
            **self._extra,
        )
        usage = response.usage
        cache_creation = getattr(usage, "cache_creation_input_tokens", 0) or 0
        cache_read = getattr(usage, "cache_read_input_tokens", 0) or 0
        return LLMResponse(
            text="".join(b.text for b in response.content if b.type == "text"),
            model=response.model,
            tokens_in=usage.input_tokens + cache_creation + cache_read,
            tokens_out=usage.output_tokens,
            cache_creation_tokens=cache_creation,
            cache_read_tokens=cache_read,
            latency_ms=int((time.monotonic() - started) * 1000),
            block_types=[b.type for b in response.content],
        )

"""LLM provider abstraction (design D5-1, D5-6).

The interface is provider-neutral so switching providers is a configuration change
(ADR-004). Phase 5.1 ships the interface only; ClaudeProvider gains real API calls
in 5.2.

Contract notes:
- `model` in ClassifyResult is the exact model id from the API response
  (`response.model`), never the alias from the environment — the audit table records
  what actually answered. The fallback path records the literal 'fallback'.
"""

from dataclasses import dataclass
from typing import Protocol


@dataclass
class ClassifyResult:
    intent: str
    sentiment: str
    language: str
    confidence: float
    rationale: str
    model: str          # exact id from the API response (response.model), not the env alias
    prompt_version: str
    tokens_in: int
    tokens_out: int
    latency_ms: int


class LLMProvider(Protocol):
    def classify(self, subject: str, body: str) -> ClassifyResult:
        """Classify one ticket. Raises on transport/validation errors — the caller
        owns retry and fallback policy (D5-2)."""
        ...


class ClaudeProvider:
    """Anthropic Claude provider. Skeleton in 5.1 — no API calls yet (filled in 5.2)."""

    def __init__(self, api_key: str, model_alias: str, prompt_version: str):
        self.api_key = api_key
        self.model_alias = model_alias
        self.prompt_version = prompt_version

    def classify(self, subject: str, body: str) -> ClassifyResult:
        raise NotImplementedError("ClaudeProvider.classify arrives in Phase 5.2")

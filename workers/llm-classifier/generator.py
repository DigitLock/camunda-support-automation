"""Generation orchestration for ticket.answer and ticket.notify (design D5-8…D5-11).

LLM call on LLM_MODEL_GENERATE → schema + local guardrails (generation_guardrails.py) →
one retry with the validator message → deterministic template from rules.py. Provider
failures degrade like classify (D5-7/D5-10). Camunda- and database-free on purpose: the
worker and tests/generation/report.py both build a Generator and call answer()/notify().
"""

import json
import logging
import os
import sys
from pathlib import Path

import anthropic

import rules
from classifier import _prompts_dir
from llm import generation_guardrails as gg
from llm.provider import ClaudeProvider, LLMProvider

log = logging.getLogger("llm-classifier.generate")

KB_FILE = "kb_tourism.md"
# Worst case per job: 2 attempts × (timeout × (max_retries + 1)) = 2 × 60 s, under the
# 90 s job timeout the worker sets for the generation job types (worker.py).
PROVIDER_TIMEOUT_SECONDS = 30.0
PROVIDER_MAX_RETRIES = 1
MAX_TOKENS = 1024

RETRY_SUFFIX = (
    "\n\nYour previous answer was rejected by the output validator: {error}\n"
    "Answer again with exactly one valid JSON object per the contract."
)

# fields the notify prompt may use — verified process data only (D5-5)
NOTIFY_FIELDS = (
    "ticketId", "resolution", "subject", "bookingRef", "refundAmountCustomer",
    "customerCurrency", "answerText", "slaDeadline",
)
ANSWER_FIELDS = ("ticketId", "subject", "body", "bookingRef")


def reply_language(variables: dict) -> str:
    """D5-8: payload `language`, else the classifier's `detectedLanguage`, else en."""
    for key in ("language", "detectedLanguage"):
        value = variables.get(key)
        if value in gg.REPLY_LANGUAGES:
            return value
    return "en"


def _load(name: str) -> str:
    path = _prompts_dir() / name
    if not path.is_file():
        sys.exit(f"error: prompt file not found: {path}")
    return path.read_text(encoding="utf-8")


class Generator:
    def __init__(self, *, answer_provider: LLMProvider, notify_provider: LLMProvider,
                 kb_text: str, answer_version: str, notify_version: str):
        self.answer_provider = answer_provider
        self.notify_provider = notify_provider
        self.kb_text = kb_text
        self.kb_ids = gg.kb_ids(kb_text)
        self.answer_version = answer_version
        self.notify_version = notify_version

    # -- public -------------------------------------------------------------------

    def answer(self, variables: dict) -> dict:
        """Returns {"variables": {answerText, answerSource, answerKbIds}, "audit": {...}}."""
        language = reply_language(variables)
        inputs = {k: variables.get(k) for k in ANSWER_FIELDS}
        message = f"Reply language: {language}\n\nTicket:\n{json.dumps(inputs, ensure_ascii=False, indent=1)}"
        result, meta = self._generate(
            self.answer_provider, message, language,
            allowed=gg.allowed_numbers(inputs, self.kb_text),
            fallback=lambda: {"text": rules.answer_handover(language), "language": language,
                              "usedKbIds": ["KB-11"]},
            prompt_version=self.answer_version,
        )
        return {
            "variables": {
                "answerText": result["text"],
                "answerSource": meta["source"],
                "answerKbIds": result["usedKbIds"],
            },
            "audit": meta,
        }

    def notify(self, variables: dict) -> dict:
        """Returns {"variables": {customerMessage, messageLanguage, notifySource}, "audit": {...}}."""
        language = reply_language(variables)
        inputs = {k: variables.get(k) for k in NOTIFY_FIELDS}
        message = f"Reply language: {language}\n\nResolved ticket:\n{json.dumps(inputs, ensure_ascii=False, indent=1)}"
        result, meta = self._generate(
            self.notify_provider, message, language,
            allowed=gg.allowed_numbers(inputs),
            fallback=lambda: {"text": rules.notify_message(language, inputs),
                              "language": language, "usedKbIds": []},
            prompt_version=self.notify_version,
        )
        return {
            "variables": {
                "customerMessage": result["text"],
                "messageLanguage": result["language"],
                "notifySource": meta["source"],
            },
            "audit": meta,
        }

    # -- internals ----------------------------------------------------------------

    def _validate(self, raw: str, language: str, allowed: set[float]):
        result, error = gg.parse_and_validate(raw)
        if error is not None:
            return None, "invalid_output", error
        code, error = gg.check_grounding(
            result, target_language=language, allowed=allowed, known_kb_ids=self.kb_ids
        )
        if code is not None:
            return None, code, error
        return result, None, None

    def _generate(self, provider, message, language, *, allowed, fallback, prompt_version):
        responses, violations, result, fallback_reason = [], [], None, None
        try:
            response = provider.complete(message)
            responses.append(response)
            result, code, error = self._validate(response.text, language, allowed)
            if result is None:
                violations.append(code)
                log.warning("generation rejected (%s), retrying once: %s | raw=%s",
                            code, error, repr(response.text[:300]))
                response = provider.complete(message + RETRY_SUFFIX.format(error=error))
                responses.append(response)
                result, code, error = self._validate(response.text, language, allowed)
                if result is None:
                    violations.append(code)
                    log.error("generation rejected after retry (%s), using template: %s | raw=%s",
                              code, error, repr(response.text[:300]))
                    fallback_reason = code
        except (anthropic.APIConnectionError, anthropic.RateLimitError,
                anthropic.InternalServerError) as exc:
            # provider failure → template (D5-10, same classes as D5-7); any other 4xx
            # propagates and becomes an incident
            log.error("LLM provider failure, using template: %s", exc)
            fallback_reason = "api_error"

        source = "llm" if result is not None else "fallback"
        if result is None:
            result = fallback()
        meta = {
            "source": source,
            "model": responses[-1].model if source == "llm" else "fallback",
            "prompt_version": prompt_version if source == "llm" else "rules",
            "tokens_in": sum(r.tokens_in for r in responses) or None,
            "tokens_out": sum(r.tokens_out for r in responses) or None,
            "cache_creation_tokens": sum(r.cache_creation_tokens for r in responses),
            "cache_read_tokens": sum(r.cache_read_tokens for r in responses),
            "latency_ms": sum(r.latency_ms for r in responses) or None,
            "violations": violations,
            "fallback_reason": fallback_reason,
            "output": result,
        }
        return result, meta


def build_from_env() -> Generator:
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key or api_key == "REPLACE_ME":
        sys.exit("error: ANTHROPIC_API_KEY is not set (see .env.example)")
    model = os.environ.get("LLM_MODEL_GENERATE", "claude-sonnet-5")
    answer_version = os.environ.get("ANSWER_PROMPT_VERSION", "answer_v1")
    notify_version = os.environ.get("NOTIFY_PROMPT_VERSION", "notify_v1")
    kb_text = _load(KB_FILE)
    common = dict(api_key=api_key, model=model, timeout=PROVIDER_TIMEOUT_SECONDS,
                  max_retries=PROVIDER_MAX_RETRIES, max_tokens=MAX_TOKENS,
                  output_schema=gg.API_SCHEMA)
    # the KB rides inside the cached system block of the answer prompt
    answer_system = _load(f"{answer_version}.md") + "\n\n# Knowledge base\n\n" + kb_text
    return Generator(
        answer_provider=ClaudeProvider(system_prompt=answer_system, **common),
        notify_provider=ClaudeProvider(system_prompt=_load(f"{notify_version}.md"), **common),
        kb_text=kb_text, answer_version=answer_version, notify_version=notify_version,
    )

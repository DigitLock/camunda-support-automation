"""Classify orchestration: LLM call → guardrails → retry → fallback (design D5-2, D5-7).

Camunda- and database-free on purpose: the worker (worker.py) and the calibration report
(tests/classification/report.py) both build a Classifier and call classify().
"""

import logging
import os
import sys
from pathlib import Path

import anthropic

import handlers
from llm import guardrails
from llm.provider import ClaudeProvider, LLMProvider

log = logging.getLogger("llm-classifier.classify")

RETRY_SUFFIX = (
    "\n\nYour previous answer was rejected by the output validator: {error}\n"
    "Answer again with exactly one valid JSON object per the contract."
)


def _prompts_dir() -> Path:
    env = os.environ.get("PROMPTS_DIR")
    if env:
        return Path(env)
    for candidate in (Path("/app/prompts"), Path(__file__).parent / ".." / ".." / "prompts"):
        if candidate.is_dir():
            return candidate.resolve()
    sys.exit("error: prompts directory not found (set PROMPTS_DIR)")


def load_prompt(version: str) -> str:
    path = _prompts_dir() / f"{version}.md"
    if not path.is_file():
        sys.exit(f"error: prompt file not found: {path} (CLASSIFY_PROMPT_VERSION={version})")
    return path.read_text(encoding="utf-8")


class Classifier:
    def __init__(self, provider: LLMProvider, threshold: float, prompt_version: str):
        self.provider = provider
        self.threshold = threshold
        self.prompt_version = prompt_version

    def classify(self, subject: str, body: str) -> dict:
        """Returns {"variables": {...process variables...}, "audit": {...}}."""
        rules_result = handlers.classify_ticket({"subject": subject, "body": body})
        user_message = f"Subject: {subject}\n\nBody: {body}"

        responses, llm_result, fallback_reason = [], None, None
        try:
            response = self.provider.complete(user_message)
            responses.append(response)
            llm_result, error = guardrails.parse_and_validate(response.text)
            if error is not None:
                log.warning(
                    "invalid LLM output, retrying once: %s | blocks=%s | raw=%s",
                    error, response.block_types, repr(response.text[:300]),
                )
                response = self.provider.complete(
                    user_message + RETRY_SUFFIX.format(error=error)
                )
                responses.append(response)
                llm_result, error = guardrails.parse_and_validate(response.text)
                if error is not None:
                    log.error(
                        "LLM output invalid after retry: %s | blocks=%s | raw=%s",
                        error, response.block_types, repr(response.text[:300]),
                    )
                    fallback_reason = "invalid_output"
        except (anthropic.APIConnectionError, anthropic.RateLimitError,
                anthropic.InternalServerError) as exc:
            # Provider failure (network, timeout, 5xx, 429): degrade to keyword routing
            # with mandatory review instead of stalling the queue (D5-7). Any other 4xx
            # (BadRequest, Authentication, PermissionDenied, NotFound) is OUR bug or
            # config error — it propagates, the job fails with retries and becomes an
            # incident in Operate, as with an audit failure (D5-3).
            log.error("LLM provider failure, falling back to keyword rules: %s", exc)
            fallback_reason = "api_error"

        variables, review_reasons, source = guardrails.apply_policy(
            llm_result, rules_result, self.threshold, fallback_reason
        )
        variables["classifierSource"] = source
        variables["promptVersion"] = self.prompt_version

        audit = {
            "model": responses[-1].model if source == "llm" else "fallback",
            "prompt_version": self.prompt_version if source == "llm" else "rules",
            "tokens_in": sum(r.tokens_in for r in responses) or None,
            "tokens_out": sum(r.tokens_out for r in responses) or None,
            "cache_creation_tokens": sum(r.cache_creation_tokens for r in responses),
            "cache_read_tokens": sum(r.cache_read_tokens for r in responses),
            "latency_ms": sum(r.latency_ms for r in responses) or None,
            "review_reasons": review_reasons,
            "fallback_reason": fallback_reason,
            "rules_intent": rules_result["intent"],
        }
        return {"variables": variables, "audit": audit}


def build_from_env() -> Classifier:
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key or api_key == "REPLACE_ME":
        sys.exit("error: ANTHROPIC_API_KEY is not set (see .env.example)")
    prompt_version = os.environ.get("CLASSIFY_PROMPT_VERSION", "classify_v2")
    provider = ClaudeProvider(
        api_key=api_key,
        model=os.environ.get("LLM_MODEL_CLASSIFY", "claude-haiku-4-5"),
        system_prompt=load_prompt(prompt_version),
        # structured output constrains the shape server-side; the wire schema has the
        # keywords structured output rejects stripped (API_SCHEMA), the full SCHEMA
        # stays the local second line of defence (D5-2)
        output_schema=guardrails.API_SCHEMA,
    )
    threshold = float(os.environ.get("CLASSIFY_CONFIDENCE_THRESHOLD", "0.8"))
    return Classifier(provider, threshold, prompt_version)

"""Guardrails for the LLM classify path (design D5-2, D5-7).

Pure functions — unit-testable without network. The enums below are the load-bearing
contract with the DMN tables and the gw-intent flows: do not extend them without a
process/DMN change. `positive` sentiment is the one accepted enum extension of Phase 5.2
(the DMN only tests `negative`; the review form consumes the value in 5.3).
"""

import json
import re

import jsonschema

INTENTS = ["change_booking", "cancel_refund", "question", "other"]
SENTIMENTS = ["positive", "neutral", "negative"]
LANGUAGES = ["ru", "en", "other"]

SCHEMA = {
    "type": "object",
    "properties": {
        "intent": {"enum": INTENTS},
        "sentiment": {"enum": SENTIMENTS},
        "detectedLanguage": {"enum": LANGUAGES},
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "rationale": {"type": "string", "maxLength": 200},
    },
    "required": ["intent", "sentiment", "detectedLanguage", "confidence", "rationale"],
    "additionalProperties": False,
}

# Structured output (output_config.format) rejects numerical constraints
# (minimum/maximum/multipleOf), string constraints (minLength/maxLength) and pattern —
# per the structured-outputs limitations in the API docs. API_SCHEMA is SCHEMA with
# those keywords stripped for the wire; the full SCHEMA stays the local second line of
# defence, so range/length violations become invalid_output → retry → fallback.
_UNSUPPORTED_BY_STRUCTURED_OUTPUT = {
    "minimum", "maximum", "multipleOf", "minLength", "maxLength", "pattern",
}


def _strip_unsupported(node):
    if isinstance(node, dict):
        return {k: _strip_unsupported(v) for k, v in node.items()
                if k not in _UNSUPPORTED_BY_STRUCTURED_OUTPUT}
    if isinstance(node, list):
        return [_strip_unsupported(v) for v in node]
    return node


API_SCHEMA = _strip_unsupported(SCHEMA)

# cross-check parameters (D5-2)
RULES_CONFIDENCE_FLOOR = 0.8   # keyword match strong enough to challenge the LLM
LLM_CONFIDENCE_CEILING = 0.9   # LLM below this loses the disagreement to review


def extract_json(text: str) -> str:
    """Tolerant extraction: strip markdown fences, then take the first balanced JSON
    object. This is a guardrail, not a workaround — the model's packaging of the answer
    is untrusted input like everything else it returns (D5-2); the schema validation
    afterwards stays strict."""
    t = text.strip()
    if t.startswith("```"):
        t = re.sub(r"^```[a-zA-Z]*\s*", "", t)
        t = re.sub(r"\s*```$", "", t)
    start = t.find("{")
    if start == -1:
        return t
    depth = 0
    for i, ch in enumerate(t[start:], start):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return t[start:i + 1]
    return t[start:]


def parse_and_validate(text: str):
    """Parse the raw LLM answer. Returns (result_dict, None) or (None, error_message);
    the error message is meant to be appended to the retry prompt verbatim."""
    try:
        parsed = json.loads(extract_json(text))
    except json.JSONDecodeError as exc:
        return None, f"not valid JSON: {exc}"
    try:
        jsonschema.validate(parsed, SCHEMA)
    except jsonschema.ValidationError as exc:
        return None, f"JSON schema violation: {exc.message}"
    return parsed, None


def apply_policy(llm_result: dict | None, rules_result: dict, threshold: float,
                 fallback_reason: str | None = None):
    """Combine the (validated) LLM result with the keyword rules into the final
    classification. Returns (variables, review_reasons, classifier_source).

    llm_result None means the LLM path failed; fallback_reason names why
    ('invalid_output' | 'api_error').
    """
    if llm_result is None:
        variables = {
            "intent": rules_result["intent"],
            "sentiment": rules_result["sentiment"],
            "confidence": rules_result["confidence"],
            "needsReview": True,           # a fallback classification is always reviewed
            "rationale": f"keyword fallback ({fallback_reason})",
            "detectedLanguage": "other",   # rules do not detect language
        }
        return variables, [fallback_reason or "fallback"], "fallback"

    reasons = []
    if llm_result["confidence"] < threshold:
        reasons.append("below_threshold")
    if (
        rules_result["intent"] != llm_result["intent"]
        and rules_result["confidence"] >= RULES_CONFIDENCE_FLOOR
        and llm_result["confidence"] < LLM_CONFIDENCE_CEILING
    ):
        reasons.append("cross_check")

    variables = {
        "intent": llm_result["intent"],
        "sentiment": llm_result["sentiment"],
        "confidence": llm_result["confidence"],
        "needsReview": bool(reasons),
        "rationale": llm_result["rationale"],
        "detectedLanguage": llm_result["detectedLanguage"],
    }
    return variables, reasons, "llm"

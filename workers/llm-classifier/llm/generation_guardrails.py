"""Guardrails for the LLM generation path — ticket.answer and ticket.notify (design D5-9).

Pure functions, unit-testable without network. The generated text is untrusted input to
the process like the classification: shape (schema), language, grounding of every number,
KB citations and length are checked locally; a violation is reported back to the model
once (retry) and then replaced by the deterministic template (fallback).
"""

import json
import re

import jsonschema

from llm.guardrails import _strip_unsupported, extract_json

REPLY_LANGUAGES = ["ru", "en"]
MAX_TEXT_CHARS = 1200

SCHEMA = {
    "type": "object",
    "properties": {
        "text": {"type": "string", "minLength": 1, "maxLength": MAX_TEXT_CHARS},
        "language": {"enum": REPLY_LANGUAGES},
        "usedKbIds": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["text", "language", "usedKbIds"],
    "additionalProperties": False,
}
API_SCHEMA = _strip_unsupported(SCHEMA)

_NUMBER_RE = re.compile(r"\d+(?:[.,]\d+)?")
_KB_ID_RE = re.compile(r"^## (KB-\d+)\b", re.MULTILINE)


def _to_number(token: str) -> float:
    return float(token.replace(",", "."))


def numbers_in(text: str) -> set[float]:
    """Every numeric token in the text as a float, so 320.5 and 320,50 compare equal."""
    return {_to_number(m) for m in _NUMBER_RE.findall(text or "")}


def kb_ids(kb_text: str) -> list[str]:
    return _KB_ID_RE.findall(kb_text)


def allowed_numbers(inputs: dict, kb_text: str = "") -> set[float]:
    """Whitelist for the grounding check: every number in the ticket variables the model
    saw (scalars and nested values, incl. the digits of bookingRef/ticketId), every number
    in the KB text and the numeric part of the KB ids (KB-01 → 1)."""
    allowed: set[float] = set()

    def walk(value):
        if isinstance(value, dict):
            for v in value.values():
                walk(v)
        elif isinstance(value, (list, tuple)):
            for v in value:
                walk(v)
        elif isinstance(value, bool) or value is None:
            return
        elif isinstance(value, (int, float)):
            allowed.add(float(value))
        else:
            allowed.update(numbers_in(str(value)))

    walk(inputs)
    allowed.update(numbers_in(kb_text))
    return allowed


def parse_and_validate(raw: str):
    """(result, None) or (None, error) — the error is appended to the retry prompt."""
    try:
        parsed = json.loads(extract_json(raw))
    except json.JSONDecodeError as exc:
        return None, f"not valid JSON: {exc}"
    try:
        jsonschema.validate(parsed, SCHEMA)
    except jsonschema.ValidationError as exc:
        return None, f"JSON schema violation: {exc.message}"
    return parsed, None


def check_grounding(result: dict, *, target_language: str, allowed: set[float],
                    known_kb_ids: list[str]):
    """Local checks after schema validation. Returns (violation_code, message) or
    (None, None). Codes: language_mismatch | grounding_violation | unknown_kb_id |
    too_long. The message names the offending value so the log shows what tripped."""
    if result["language"] != target_language:
        return "language_mismatch", (
            f"language must be '{target_language}', got '{result['language']}'"
        )
    if len(result["text"]) > MAX_TEXT_CHARS:
        return "too_long", f"text has {len(result['text'])} characters, max {MAX_TEXT_CHARS}"
    unknown = [k for k in result["usedKbIds"] if k not in known_kb_ids]
    if unknown:
        return "unknown_kb_id", f"usedKbIds not in the knowledge base: {unknown}"
    stray = sorted(numbers_in(result["text"]) - allowed)
    if stray:
        shown = [int(n) if n.is_integer() else n for n in stray]
        return "grounding_violation", (
            f"numbers not present in the ticket or the knowledge base: {shown} — "
            "remove them or point to where the customer finds the figure"
        )
    return None, None

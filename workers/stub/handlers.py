"""Pure job handlers for the Phase 2 stub worker: dict of variables in, dict of variables out.

No SDK imports — each function is portable to Go (Phase 4) one handler at a time.
Behaviour follows docs/design/process-v1.md §5.2, §5.6 and §7. Routing moved to DMN
in Phase 3 (docs/design/routing-v1.md); the worker has no routing handler anymore.
"""

from datetime import datetime, timezone

import rules


def classify_ticket(variables: dict) -> dict:
    subject = (variables.get("subject") or "").lower()
    body = (variables.get("body") or "").lower()

    matched = rules.CLASSIFY_DEFAULT
    for rule in rules.CLASSIFY_RULES:
        if any(k in subject for k in rule.get("contains", [])) or any(
            subject.startswith(k) for k in rule.get("starts_with", [])
        ):
            matched = rule
            break

    confidence = matched["confidence"]
    sentiment = (
        "negative"
        if any(k in body for k in rules.NEGATIVE_BODY_KEYWORDS)
        else "neutral"
    )
    return {
        "intent": matched["intent"],
        "sentiment": sentiment,
        "confidence": confidence,
        "needsReview": confidence < rules.REVIEW_THRESHOLD,
    }


def change_booking(variables: dict) -> dict:
    return {}


def cancel_booking(variables: dict) -> dict:
    return {}


def answer_ticket(variables: dict) -> dict:
    return {}


def notify_customer(variables: dict) -> dict:
    resolution = variables.get("resolution")
    return {
        "notificationTemplate": f"{rules.NOTIFICATION_TEMPLATE_PREFIX}{resolution}",
        "notifiedAt": datetime.now(timezone.utc).isoformat(),
    }


HANDLERS = {
    "ticket.classify": classify_ticket,
    "booking.change": change_booking,
    "booking.cancel": cancel_booking,
    "ticket.answer": answer_ticket,
    "ticket.notify": notify_customer,
}

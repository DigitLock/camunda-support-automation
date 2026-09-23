"""Keyword tables and thresholds for the Phase 2 stub worker.

Plain data only — the values come from docs/design/process-v1.md §7 (classification rules)
and §5.3 (routing). handlers.py interprets these tables; nothing here executes.
"""

# ticket.classify — evaluated in order, first match wins (design §7).
# A rule matches when the lower-cased subject contains any of `contains`
# or starts with any of `starts_with`.
CLASSIFY_RULES = [
    {"contains": ["change"], "intent": "change_booking", "confidence": 0.92},
    {"contains": ["cancel", "refund"], "intent": "cancel_refund", "confidence": 0.90},
    {"contains": ["?"], "starts_with": ["how", "what", "when"], "intent": "question", "confidence": 0.85},
    {"contains": ["unclear"], "intent": "question", "confidence": 0.40},
]
CLASSIFY_DEFAULT = {"intent": "other", "confidence": 0.80}

# sentiment = "negative" if the body contains any of these, else "neutral" (design §7)
NEGATIVE_BODY_KEYWORDS = ["angry", "terrible"]

# needsReview = confidence < REVIEW_THRESHOLD (design §5.2, decision D2-4)
REVIEW_THRESHOLD = 0.7

# ticket.route (design §5.3)
TEAM_BY_INTENT = {
    "change_booking": "bookings",
    "cancel_refund": "refunds",
    "question": "support",
    "other": "escalation",
}
PREMIUM_TIER = "premium"          # customerTier value that yields high priority
SLA_HOURS = {"high": 4, "normal": 24}

# ticket.notify (design §5.6)
NOTIFICATION_TEMPLATE_PREFIX = "notify-"

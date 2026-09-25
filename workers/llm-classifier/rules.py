"""Keyword tables and thresholds for the stub worker.

Plain data only — the values come from docs/design/process-v1.md §7 (classification rules).
handlers.py interprets these tables; nothing here executes. Routing rules lived here until
Phase 3 moved them to DMN (docs/design/routing-v1.md).
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

# ticket.notify (design §5.6)
NOTIFICATION_TEMPLATE_PREFIX = "notify-"

# ticket.answer / ticket.notify fallback templates (design D5-9): deterministic customer
# text when the LLM output fails the guardrails or the provider is down. Only verified
# process data is interpolated; missing values degrade to a neutral sentence.
ANSWER_HANDOVER = {
    "en": "Thank you for your question. A support agent will follow up on this ticket "
          "shortly with the details for your booking.",
    "ru": "Спасибо за ваш вопрос. Специалист поддержки в ближайшее время ответит по этому "
          "обращению с учётом деталей вашего бронирования.",
}

NOTIFY_TEMPLATES = {
    "en": {
        "greeting": "Hello,",
        "booking_changed": "the requested change has been applied to your booking{ref}. "
                           "The updated documents will follow separately.",
        "refund_issued": "your booking{ref} has been cancelled and a refund{amount} was "
                         "issued to the original payment method. The credit appears within "
                         "the time your payment provider needs.",
        "answered": "{answer}",
        "agent_handled": "a support agent has handled your request{ref}. You can reply to "
                         "this message with any further questions.",
        "closing": "Kind regards,\nCustomer Support",
        "ref": " {ref}",
        "amount": " of {amount} {currency}",
    },
    "ru": {
        "greeting": "Здравствуйте!",
        "booking_changed": "Запрошенное изменение внесено в ваше бронирование{ref}. "
                           "Обновлённые документы придут отдельным письмом.",
        "refund_issued": "Ваше бронирование{ref} отменено, возврат{amount} оформлен на "
                         "исходный способ оплаты. Средства поступят в срок, установленный "
                         "вашим платёжным провайдером.",
        "answered": "{answer}",
        "agent_handled": "Специалист поддержки обработал ваше обращение{ref}. На это письмо "
                         "можно ответить, если остались вопросы.",
        "closing": "С уважением,\nСлужба поддержки",
        "ref": " {ref}",
        "amount": " в размере {amount} {currency}",
    },
}


def answer_handover(language: str) -> str:
    return ANSWER_HANDOVER.get(language, ANSWER_HANDOVER["en"])


def notify_message(language: str, inputs: dict) -> str:
    t = NOTIFY_TEMPLATES.get(language, NOTIFY_TEMPLATES["en"])
    ref = t["ref"].format(ref=inputs["bookingRef"]) if inputs.get("bookingRef") else ""
    amount = ""
    if inputs.get("refundAmountCustomer") is not None:
        amount = t["amount"].format(amount=inputs["refundAmountCustomer"],
                                    currency=inputs.get("customerCurrency") or "")
    body = t.get(inputs.get("resolution") or "", t["agent_handled"]).format(
        ref=ref, amount=amount, answer=inputs.get("answerText") or answer_handover(language)
    )
    return f"{t['greeting']}\n\n{body}\n\n{t['closing']}"

"""LLM classifier worker (Phase 5): serves ticket.classify, review.record, ticket.answer,
ticket.notify.

ticket.classify runs the real LLM path since 5.2: classifier.py (Claude call → guardrails
→ retry → keyword fallback, D5-2/D5-7), mandatory audit to PostgreSQL (audit.py, D5-3).
review.record (5.3) writes the human review outcome to classification_review, pairing the
form's final values with the LLM's from the audit (D5-4). ticket.answer / ticket.notify
(5.4) generate customer text on LLM_MODEL_GENERATE through generator.py (grounded answer
from the KB, final notification from process data — D5-8…D5-11); delivery stays a log
line. Design: docs/design/llm-classifier-v1.md.

Configuration via environment: CAMUNDA_BASE_URL, CAMUNDA_USER, CAMUNDA_PASSWORD,
DATABASE_URL, ANTHROPIC_API_KEY (all required); LLM_MODEL_CLASSIFY, LLM_MODEL_GENERATE,
CLASSIFY_CONFIDENCE_THRESHOLD, CLASSIFY_PROMPT_VERSION, ANSWER_PROMPT_VERSION,
NOTIFY_PROMPT_VERSION, PROMPTS_DIR.
"""

import asyncio
import http.server
import logging
import os
import signal
import sys
import threading

from camunda_orchestration_sdk import CamundaAsyncClient, WorkerConfig

import audit
import classifier
import generator
import handlers
from handlers import HANDLERS

log = logging.getLogger("llm-classifier")


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"error: {name} is not set (see .env.example)")
    return value


def make_classify_callback(clf: classifier.Classifier, auditor: audit.Audit):
    async def callback(job) -> dict:
        variables = job.variables.to_dict() if job.variables else {}
        outcome = clf.classify(variables.get("subject") or "", variables.get("body") or "")
        result, meta = outcome["variables"], outcome["audit"]
        # mandatory audit — an exception here fails the job on purpose (D5-3)
        auditor.write_llm(
            job_type="classify",
            ticket_id=str(variables.get("ticketId")),
            run_id=variables.get("runId"),
            model=meta["model"],
            prompt_version=meta["prompt_version"],
            input_text=f"{variables.get('subject') or ''}\n{variables.get('body') or ''}",
            output={
                **result,
                "reviewReasons": meta["review_reasons"],
                "fallback_reason": meta["fallback_reason"],
                "rules_intent": meta["rules_intent"],
                "cache_creation_tokens": meta["cache_creation_tokens"],
                "cache_read_tokens": meta["cache_read_tokens"],
            },
            confidence=result.get("confidence"),
            needs_review=result.get("needsReview"),
            fallback_used=result["classifierSource"] == "fallback",
            tokens_in=meta["tokens_in"],
            tokens_out=meta["tokens_out"],
            latency_ms=meta["latency_ms"],
        )
        log.info(
            "job=ticket.classify ticketId=%s -> %s", variables.get("ticketId"), result
        )
        return result

    return callback


def make_generate_callback(job_type: str, gen: generator.Generator, auditor: audit.Audit):
    """ticket.answer / ticket.notify: LLM text + mandatory audit row (D5-3). notify keeps
    the deterministic notificationTemplate/notifiedAt from handlers.py; delivery is the
    log line (D5-5)."""
    audit_type = "answer" if job_type == "ticket.answer" else "notify"

    async def callback(job) -> dict:
        variables = job.variables.to_dict() if job.variables else {}
        ticket_id = str(variables.get("ticketId"))
        if audit_type == "answer":
            outcome = gen.answer(variables)
            result = outcome["variables"]
        else:
            outcome = gen.notify(variables)
            result = {**handlers.notify_customer(variables), **outcome["variables"]}
        meta = outcome["audit"]
        auditor.write_llm(
            job_type=audit_type,
            ticket_id=ticket_id,
            run_id=variables.get("runId"),
            model=meta["model"],
            prompt_version=meta["prompt_version"],
            input_text=f"{variables.get('subject') or ''}\n{variables.get('body') or ''}"
                       f"\n{variables.get('resolution') or ''}",
            output={
                **meta["output"],
                "source": meta["source"],
                "violations": meta["violations"],
                "fallback_reason": meta["fallback_reason"],
                "cache_creation_tokens": meta["cache_creation_tokens"],
                "cache_read_tokens": meta["cache_read_tokens"],
            },
            fallback_used=meta["source"] == "fallback",
            tokens_in=meta["tokens_in"],
            tokens_out=meta["tokens_out"],
            latency_ms=meta["latency_ms"],
        )
        if audit_type == "notify":
            # delivery stub (D5-5): the message is logged, not sent
            log.info("deliver ticketId=%s language=%s template=%s message=%r", ticket_id,
                     result["messageLanguage"], result["notificationTemplate"],
                     result["customerMessage"])
        log.info("job=%s ticketId=%s -> source=%s model=%s kb=%s chars=%d", job_type,
                 ticket_id, meta["source"], meta["model"],
                 result.get("answerKbIds", []), len(meta["output"]["text"]))
        return result

    return callback


def make_review_callback(auditor: audit.Audit):
    async def callback(job) -> dict:
        variables = job.variables.to_dict() if job.variables else {}
        ticket_id = str(variables.get("ticketId"))
        run_id = variables.get("runId")
        reviewed_by = variables.get("reviewedBy") or "unknown"
        llm_intent, llm_sentiment = auditor.latest_classify(ticket_id=ticket_id, run_id=run_id)
        review = {
            "reviewed_by": reviewed_by,
            "llm_intent": llm_intent,
            "final_intent": variables.get("intent"),
            "llm_sentiment": llm_sentiment,
            "final_sentiment": variables.get("sentiment"),
            "escalated": bool(variables.get("escalate")),
        }
        # mandatory write — an exception fails the job on purpose (D5-3)
        auditor.write_review(ticket_id=ticket_id, run_id=run_id, **review)
        log.info("job=review.record ticketId=%s -> %s", ticket_id, review)
        return {}

    return callback


def make_callback(job_type: str, handler):
    async def callback(job) -> dict:
        variables = job.variables.to_dict() if job.variables else {}
        result = handler(variables)
        log.info("job=%s ticketId=%s -> %s", job_type, variables.get("ticketId"), result)
        return result

    return callback


class _HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 (stdlib API)
        status = 200 if self.path == "/healthz" else 404
        self.send_response(status)
        self.end_headers()
        self.wfile.write(b"ok\n" if status == 200 else b"")

    def log_message(self, *args):  # silence per-request lines
        pass


def start_health_server() -> None:
    server = http.server.ThreadingHTTPServer(("0.0.0.0", 8081), _HealthHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


async def main() -> None:
    auditor = audit.from_env()
    auditor.connect_with_retry()
    clf = classifier.build_from_env()  # fails fast on missing key or prompt file
    gen = generator.build_from_env()   # same for the answer/notify prompts and the KB

    client = CamundaAsyncClient(
        configuration={
            "CAMUNDA_REST_ADDRESS": require_env("CAMUNDA_BASE_URL"),
            "CAMUNDA_AUTH_STRATEGY": "BASIC",
            "CAMUNDA_BASIC_AUTH_USERNAME": require_env("CAMUNDA_USER"),
            "CAMUNDA_BASIC_AUTH_PASSWORD": require_env("CAMUNDA_PASSWORD"),
        }
    )
    callbacks = {
        "ticket.classify": make_classify_callback(clf, auditor),
        "ticket.answer": make_generate_callback("ticket.answer", gen, auditor),
        "ticket.notify": make_generate_callback("ticket.notify", gen, auditor),
        "review.record": make_review_callback(auditor),
    }
    assert set(HANDLERS) <= set(callbacks), "every pure handler needs a callback"
    for job_type, cb in callbacks.items():
        # generation: 2 attempts × 30 s × (1 + 1 retry) = 120 s worst case in theory, but
        # the SDK retries only transport/429/5xx and each attempt is capped at 30 s; the
        # 90 s job timeout covers one full attempt plus the guardrail retry (D5-9)
        timeout_ms = 90_000 if job_type in ("ticket.answer", "ticket.notify") else 30_000
        client.create_job_worker(
            config=WorkerConfig(job_type=job_type, job_timeout_milliseconds=timeout_ms),
            callback=cb,
        )
    start_health_server()
    log.info(
        "polling job types: %s (prompts %s, %s, %s)", ", ".join(callbacks),
        clf.prompt_version, gen.answer_version, gen.notify_version,
    )

    # SIGTERM (compose stop) cancels run_workers(), which stops all pollers cleanly.
    loop = asyncio.get_running_loop()
    workers_task = asyncio.ensure_future(client.run_workers())
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, workers_task.cancel)
    try:
        await workers_task
    except asyncio.CancelledError:
        log.info("shutdown: workers stopped")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    # The SDK logs each empty poll at DEBUG; keep its logger at INFO so job lines stay visible.
    logging.getLogger("camunda_orchestration_sdk").setLevel(
        getattr(logging, os.environ.get("LOG_LEVEL", "INFO").upper(), logging.INFO)
    )
    asyncio.run(main())

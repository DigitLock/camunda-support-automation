"""LLM classifier worker (Phase 5): serves ticket.classify, ticket.answer, ticket.notify.

Phase 5.1 skeleton: the handlers still run the deterministic rules (rules.py) — no LLM
calls yet — but every ticket.classify is audited to PostgreSQL (audit.py, D5-3) and the
output carries classifierSource / promptVersion. The Claude provider (llm/provider.py)
is wired in Phase 5.2. Design: docs/design/llm-classifier-v1.md.

Configuration via environment: CAMUNDA_BASE_URL, CAMUNDA_USER, CAMUNDA_PASSWORD,
DATABASE_URL (required); LLM_MODEL_CLASSIFY, LLM_MODEL_GENERATE, ANTHROPIC_API_KEY,
CLASSIFY_CONFIDENCE_THRESHOLD, CLASSIFY_PROMPT_VERSION (used from 5.2 on).
"""

import asyncio
import http.server
import logging
import os
import signal
import sys
import threading
import time

from camunda_orchestration_sdk import CamundaAsyncClient, WorkerConfig

import audit
from handlers import HANDLERS

log = logging.getLogger("llm-classifier")

PROMPT_VERSION = os.environ.get("CLASSIFY_PROMPT_VERSION", "classify_v1")


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"error: {name} is not set (see .env.example)")
    return value


def make_callback(job_type: str, handler, auditor: audit.Audit):
    async def callback(job) -> dict:
        variables = job.variables.to_dict() if job.variables else {}
        started = time.monotonic()
        result = handler(variables)
        if job_type == "ticket.classify":
            # 5.1: rules-based fallback is the only path; LLM arrives in 5.2 (D5-2)
            result["classifierSource"] = "fallback"
            result["promptVersion"] = PROMPT_VERSION
            # mandatory audit — an exception here fails the job on purpose (D5-3)
            auditor.write_classify(
                ticket_id=str(variables.get("ticketId")),
                run_id=variables.get("runId"),
                model="fallback",
                prompt_version="rules",
                subject=variables.get("subject") or "",
                body=variables.get("body") or "",
                output=result,
                confidence=result.get("confidence"),
                needs_review=result.get("needsReview"),
                fallback_used=True,
                latency_ms=int((time.monotonic() - started) * 1000),
            )
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

    client = CamundaAsyncClient(
        configuration={
            "CAMUNDA_REST_ADDRESS": require_env("CAMUNDA_BASE_URL"),
            "CAMUNDA_AUTH_STRATEGY": "BASIC",
            "CAMUNDA_BASIC_AUTH_USERNAME": require_env("CAMUNDA_USER"),
            "CAMUNDA_BASIC_AUTH_PASSWORD": require_env("CAMUNDA_PASSWORD"),
        }
    )
    for job_type, handler in HANDLERS.items():
        client.create_job_worker(
            config=WorkerConfig(job_type=job_type, job_timeout_milliseconds=30_000),
            callback=make_callback(job_type, handler, auditor),
        )
    start_health_server()
    log.info("polling job types: %s (prompt version %s)", ", ".join(HANDLERS), PROMPT_VERSION)

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

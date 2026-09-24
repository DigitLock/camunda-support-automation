"""Stub worker: subscribes to the remaining Python job types with the official SDK.

Job types: ticket.classify, ticket.answer, ticket.notify (routing → DMN in Phase 3,
booking.* → the Go worker in Phase 4). Runs as a container in the `workers` compose
profile (ADR-006); a local venv run stays available as the dev fallback (README).

Configuration via environment (design §7): CAMUNDA_BASE_URL, CAMUNDA_USER, CAMUNDA_PASSWORD.
The names are mapped onto the SDK's own configuration keys below, so the contract stays the
design's while the SDK keeps its documented settings.
"""

import asyncio
import http.server
import logging
import os
import signal
import sys
import threading

from camunda_orchestration_sdk import CamundaAsyncClient, WorkerConfig

from handlers import HANDLERS

log = logging.getLogger("stub-worker")


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"error: {name} is not set (see .env.example)")
    return value


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
            callback=make_callback(job_type, handler),
        )
    start_health_server()
    log.info("polling job types: %s", ", ".join(HANDLERS))

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

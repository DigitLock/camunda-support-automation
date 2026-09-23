"""Phase 2 stub worker: subscribes to all six job types with the official Python SDK.

Configuration via environment (design §7): CAMUNDA_BASE_URL, CAMUNDA_USER, CAMUNDA_PASSWORD.
The names are mapped onto the SDK's own configuration keys below, so the contract stays the
design's while the SDK keeps its documented settings.
"""

import asyncio
import logging
import os
import sys

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
    log.info("polling job types: %s", ", ".join(HANDLERS))
    await client.run_workers()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass

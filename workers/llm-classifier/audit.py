"""Mandatory audit writes to PostgreSQL (design D5-3).

One row per ticket.classify (llm_audit) and one per review.record (classification_review,
5.3). A failed write raises — the SDK then fails the job with
retries - 1, and exhausted retries surface as an incident in Operate. That is deliberate:
an unauditable classification must not complete silently (verified against the SDK dev39
source: any exception in a handler callback becomes a fail-job action).
"""

import hashlib
import json
import logging
import os
import time

import psycopg

log = logging.getLogger("llm-classifier.audit")

_CONNECT_RETRIES = 10
_CONNECT_BACKOFF_SECONDS = 3


class Audit:
    def __init__(self, database_url: str):
        self._url = database_url
        self._conn = None

    def connect_with_retry(self) -> None:
        """Called at startup: PostgreSQL may still be warming up."""
        for attempt in range(1, _CONNECT_RETRIES + 1):
            try:
                self._conn = psycopg.connect(self._url, autocommit=True)
                log.info("audit database connected")
                return
            except psycopg.OperationalError as exc:
                log.warning(
                    "audit database not ready (attempt %d/%d): %s",
                    attempt, _CONNECT_RETRIES, exc,
                )
                time.sleep(_CONNECT_BACKOFF_SECONDS)
        raise RuntimeError(f"audit database unreachable after {_CONNECT_RETRIES} attempts")

    def _connection(self):
        if self._conn is None or self._conn.closed:
            self._conn = psycopg.connect(self._url, autocommit=True)
        return self._conn

    def write_classify(
        self,
        *,
        ticket_id: str,
        run_id: str | None,
        model: str,
        prompt_version: str,
        subject: str,
        body: str,
        output: dict,
        confidence: float | None,
        needs_review: bool | None,
        fallback_used: bool,
        tokens_in: int | None = None,
        tokens_out: int | None = None,
        latency_ms: int | None = None,
    ) -> None:
        input_hash = hashlib.sha256(f"{subject}\n{body}".encode()).hexdigest()
        try:
            self._connection().execute(
                """
                INSERT INTO llm_audit
                    (ticket_id, run_id, job_type, model, prompt_version, input_hash,
                     output, confidence, needs_review, fallback_used,
                     tokens_in, tokens_out, latency_ms)
                VALUES (%s, %s, 'classify', %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    ticket_id, run_id, model, prompt_version, input_hash,
                    json.dumps(output), confidence, needs_review, fallback_used,
                    tokens_in, tokens_out, latency_ms,
                ),
            )
        except psycopg.Error as exc:
            self._reset()
            raise RuntimeError(f"audit write failed: {exc}") from exc

    def latest_classify(self, *, ticket_id: str, run_id: str | None) -> tuple[str | None, str | None]:
        """(intent, sentiment) of the newest classify row for the ticket/run, or (None, None)."""
        try:
            row = self._connection().execute(
                """
                SELECT output->>'intent', output->>'sentiment'
                FROM llm_audit
                WHERE ticket_id = %s AND run_id IS NOT DISTINCT FROM %s AND job_type = 'classify'
                ORDER BY id DESC LIMIT 1
                """,
                (ticket_id, run_id),
            ).fetchone()
        except psycopg.Error as exc:
            self._reset()
            raise RuntimeError(f"audit read failed: {exc}") from exc
        return (row[0], row[1]) if row else (None, None)

    def write_review(
        self,
        *,
        ticket_id: str,
        run_id: str | None,
        reviewed_by: str,
        llm_intent: str | None,
        final_intent: str | None,
        llm_sentiment: str | None,
        final_sentiment: str | None,
        escalated: bool,
    ) -> None:
        try:
            self._connection().execute(
                """
                INSERT INTO classification_review
                    (ticket_id, run_id, reviewed_by, llm_intent, final_intent,
                     llm_sentiment, final_sentiment, escalated)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (ticket_id, run_id, reviewed_by, llm_intent, final_intent,
                 llm_sentiment, final_sentiment, escalated),
            )
        except psycopg.Error as exc:
            self._reset()
            raise RuntimeError(f"review write failed: {exc}") from exc

    def _reset(self) -> None:
        """Close so the next attempt reconnects cleanly; the caller lets the job fail (D5-3)."""
        try:
            if self._conn is not None:
                self._conn.close()
        except Exception:
            pass
        self._conn = None


def from_env() -> Audit:
    url = os.environ.get("DATABASE_URL")
    if not url:
        raise SystemExit("error: DATABASE_URL is not set (see .env.example)")
    return Audit(url)

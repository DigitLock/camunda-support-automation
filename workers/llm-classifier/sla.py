"""sla.escalate job handler (Phase 6.3, design D6-5 / operations-v1.md §4).

Process v10 fires the non-interrupting timer boundary `sla-timer` on `handle-by-agent` at
`slaDeadline` and runs the service task `escalate-sla` (this job type). Escalation raises the
priority of the live agent task and records the breach; it never reassigns or cancels the
task — the agent finishes the ticket, the breach is a fact for analytics (D6-5).

Outcomes, all completing the job with slaBreached = true and an escalatedAt field (ISO 8601
UTC with milliseconds and "Z", like slaDeadline; null unless a PATCH was made — the output
mapping reads it unconditionally):
  escalated          open task found, priority < 90 → PATCH /v2/user-tasks/{key}
                     {changeset: {priority: 90, candidateGroups: ["supervisors"]}}
  already_escalated  open task already at priority ≥ 90 → no second PATCH
  no_open_task       the agent finished at the deadline → nothing to escalate
Every outcome writes one sla_escalation row (audit.py); a failed write fails the job (D5-3).
Transport errors and 5xx fail the job with retries - 1 and a 10 s backoff; a 4xx is a bug in
this request and fails the job with retries = 0 (incident now, same reasoning as D5-7).
"""

import logging
from datetime import datetime, timezone

import httpx
from camunda_orchestration_sdk import (
    Changeset,
    JobFailure,
    UserTaskSearchQuery,
    UserTaskSearchQueryFilter,
    UserTaskStateExactMatch,
    UserTaskUpdateRequest,
    errors,
)

log = logging.getLogger("llm-classifier.sla")

ELEMENT_ID = "handle-by-agent"
ESCALATED_PRIORITY = 90
CANDIDATE_GROUP = "supervisors"
RETRY_BACKOFF_MS = 10_000
ACTION = "sla-escalation"


def _iso_utc_ms(dt: datetime) -> str:
    """2026-09-26T19:32:49.751Z — the process-variable format of slaDeadline (D3-11)."""
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"


def make_sla_callback(client, auditor):
    async def callback(job) -> dict:
        variables = job.variables.to_dict() if job.variables else {}
        ticket_id = str(variables.get("ticketId"))
        run_id = variables.get("runId")
        sla_deadline = variables.get("slaDeadline")
        instance_key = str(job.process_instance_key)
        now = datetime.now(timezone.utc)
        retries_left = job.retries - 1 if job.retries and job.retries > 0 else 0

        try:
            found = await client.search_user_tasks(
                data=UserTaskSearchQuery(
                    filter_=UserTaskSearchQueryFilter(
                        process_instance_key=instance_key,
                        element_id=ELEMENT_ID,
                        state=UserTaskStateExactMatch.CREATED,
                    )
                )
            )
            tasks = list(found.items or [])
            task = tasks[0] if tasks else None
            previous = task.priority if task is not None else None
            if task is None:
                outcome, new_priority, escalated_at = "no_open_task", None, None
            elif previous is not None and previous >= ESCALATED_PRIORITY:
                outcome, new_priority, escalated_at = "already_escalated", previous, None
            else:
                await client.update_user_task(
                    task.user_task_key,
                    data=UserTaskUpdateRequest(
                        changeset=Changeset(
                            priority=ESCALATED_PRIORITY, candidate_groups=[CANDIDATE_GROUP]
                        ),
                        action=ACTION,
                    ),
                )
                outcome, new_priority, escalated_at = "escalated", ESCALATED_PRIORITY, now
        except httpx.TransportError as exc:  # connect/read/timeout: the API is unreachable
            raise JobFailure(
                f"sla.escalate: transport error, retrying: {exc}",
                retries=retries_left, retry_back_off=RETRY_BACKOFF_MS,
            ) from exc
        except errors.ApiError as exc:
            if exc.status_code >= 500:  # 500/503/504: the cluster is busy, retry with backoff
                raise JobFailure(
                    f"sla.escalate: HTTP {exc.status_code} from the user task API, retrying",
                    retries=retries_left, retry_back_off=RETRY_BACKOFF_MS,
                ) from exc
            raise JobFailure(  # 4xx: our request is wrong — surface it now, no retry
                f"sla.escalate: request rejected with HTTP {exc.status_code} (no retry): "
                f"{exc.content.decode(errors='ignore')[:300]}",
                retries=0,
            ) from exc

        # mandatory audit — an exception here fails the job on purpose (D5-3)
        auditor.write_sla_escalation(
            ticket_id=ticket_id, run_id=run_id, process_instance_key=instance_key,
            user_task_key=task.user_task_key if task is not None else None,
            sla_deadline=sla_deadline, escalated_at=now,
            previous_priority=previous, new_priority=new_priority, outcome=outcome,
        )
        log.info(
            "job=sla.escalate ticketId=%s instance=%s outcome=%s taskKey=%s priority=%s->%s",
            ticket_id, instance_key, outcome,
            task.user_task_key if task is not None else "-", previous, new_priority,
        )
        return {
            "slaBreached": True,
            "escalated": outcome == "escalated",
            # same shape as slaDeadline (D3-11): plain ISO 8601 UTC, milliseconds, "Z"
            "escalatedAt": _iso_utc_ms(escalated_at) if escalated_at else None,
            "escalatedTaskKey": task.user_task_key if task is not None else None,
        }

    return callback

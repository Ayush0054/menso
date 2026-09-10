"""Idempotent, fail-soft schedule registration."""

from __future__ import annotations

from typing import Any

from agno.scheduler import ScheduleManager
from agno.utils.log import log_info, log_warning

from app.settings import get_settings
from db.session import get_db


def _register(
    manager: ScheduleManager,
    *,
    name: str,
    cron: str,
    endpoint: str,
    payload: dict[str, Any],
    description: str,
    enabled: bool,
) -> None:
    try:
        schedule = manager.create(
            name=name,
            cron=cron,
            endpoint=endpoint,
            payload=payload,
            description=description,
            if_exists="update",
        )
        if bool(schedule.enabled) != enabled:
            updated = manager.enable(schedule.id) if enabled else manager.disable(schedule.id)
            if updated is None or bool(updated.enabled) != enabled:
                raise RuntimeError(f"schedule state could not be set to enabled={enabled}")
    except Exception as exc:
        log_warning(f"schedules: could not register {name!r}: {exc}")
    else:
        state = "enabled" if enabled else "disabled by default"
        log_info(f"schedules: registered {name!r} ({state})")


def register_schedules() -> None:
    settings = get_settings()
    try:
        manager = ScheduleManager(get_db())
    except Exception as exc:
        log_warning(f"schedules: could not initialize ScheduleManager: {exc}")
        return

    _register(
        manager,
        name="deployment-check",
        cron="0 13 * * *",
        endpoint="/workflows/deployment-check/runs",
        payload={"message": "Scheduled deployment readiness check."},
        description="Daily deterministic deployment readiness report.",
        enabled=True,
    )
    _register(
        manager,
        name="run-evals",
        cron=settings.eval_schedule_cron,
        endpoint="/workflows/run-evals/runs",
        payload={"message": "Scheduled explicit Menso eval run."},
        description="Model-bearing eval suite; disabled until explicitly enabled.",
        enabled=settings.eval_schedule_enabled,
    )
    _register(
        manager,
        name="agent-improvement",
        cron=settings.improvement_schedule_cron,
        endpoint="/workflows/agent-improvement/runs",
        payload={
            "message": "Explicit-only sentinel; start manually with typed evidence and a verified admin JWT."
        },
        description=(
            "Admin improvement proposal workflow. It stays disabled because every run requires an explicit, "
            "ownership-bound evidence selection and verified maintainer identity."
        ),
        enabled=False,
    )

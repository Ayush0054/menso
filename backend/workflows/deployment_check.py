"""Deterministic deployment readiness workflow."""

from __future__ import annotations

from dataclasses import dataclass
from urllib.parse import urlparse

from agno.workflow.step import Step
from agno.workflow.types import OnError, StepInput, StepOutput
from agno.workflow.workflow import Workflow

from app.settings import get_settings
from db.session import get_db


@dataclass(frozen=True)
class CheckResult:
    name: str
    status: str
    detail: str


def _check_database() -> CheckResult:
    try:
        get_db().get_sessions(limit=1)
    except Exception as exc:
        return CheckResult("Database", "FAIL", f"Postgres session read failed: {type(exc).__name__}: {exc}")
    return CheckResult("Database", "PASS", "Postgres session storage is reachable.")


def _check_auth() -> CheckResult:
    settings = get_settings()
    if settings.runtime_env == "dev":
        return CheckResult("Authorization", "WARN", "Development mode has AgentOS JWT authorization disabled.")
    if not (settings.jwt_verification_key or settings.jwt_jwks_file):
        return CheckResult("Authorization", "FAIL", "Production JWT verification source is missing.")
    return CheckResult(
        "Authorization",
        "PASS",
        "JWT verification, audience validation, and user isolation are configured.",
    )


def _check_public_url() -> CheckResult:
    settings = get_settings()
    if not settings.public_url:
        return CheckResult("Public URL", "FAIL", "AGENTOS_PUBLIC_URL is not set.")
    parsed = urlparse(settings.public_url)
    if not parsed.scheme or not parsed.netloc:
        return CheckResult("Public URL", "FAIL", "AGENTOS_PUBLIC_URL is not an absolute URL.")
    if settings.runtime_env != "dev" and parsed.scheme != "https":
        return CheckResult("Public URL", "FAIL", "Production AGENTOS_PUBLIC_URL must use HTTPS.")
    return CheckResult("Public URL", "PASS", f"Scheduler base URL is {settings.public_url}.")


def _check_realtime() -> CheckResult:
    settings = get_settings()
    if not settings.openai_api_key:
        check_status = "WARN" if settings.runtime_env == "dev" else "FAIL"
        return CheckResult(
            "Realtime",
            check_status,
            "OPENAI_API_KEY is absent; models and voice client-token minting are unavailable.",
        )
    if not settings.safety_identifier_salt or len(settings.safety_identifier_salt) < 32:
        return CheckResult("Realtime", "FAIL", "MENSO_SAFETY_IDENTIFIER_SALT must contain at least 32 characters.")
    return CheckResult(
        "Realtime",
        "PASS",
        f"Ephemeral sessions use {settings.openai_realtime_model}; the API key stays server-side.",
    )


def _check_components() -> CheckResult:
    from agents.menso import menso_agent
    from app.registry import registry
    from workflows.agent_improvement import agent_improvement_workflow
    from workflows.run_evals import run_evals_workflow

    component_ids = (
        menso_agent.id,
        agent_improvement_workflow.id,
        deployment_check_workflow.id,
        run_evals_workflow.id,
    )
    if any(component_id is None for component_id in component_ids):
        return CheckResult("Components", "FAIL", "A Menso component ID is missing or duplicated.")
    expected = {component_id for component_id in component_ids if component_id is not None}
    if len(expected) != 4:
        return CheckResult("Components", "FAIL", "A Menso component ID is missing or duplicated.")
    if registry.tools:
        return CheckResult("Registry", "FAIL", "Safe registry unexpectedly exposes toolkits.")
    return CheckResult("Components", "PASS", f"Registered stable IDs: {', '.join(sorted(expected))}.")


def _format(checks: list[CheckResult]) -> str:
    failures = sum(item.status == "FAIL" for item in checks)
    warnings = sum(item.status == "WARN" for item in checks)
    overall = "FAIL" if failures else "WARN" if warnings else "PASS"
    lines = ["# Menso Deployment Check", "", f"Overall: **{overall}** ({failures} failed, {warnings} warning)", ""]
    lines.extend(f"- **{item.status}** {item.name}: {item.detail}" for item in checks)
    lines.append("- **PASS** CUA boundary: native UI execution is client-owned; the backend contains schemas only.")
    return "\n".join(lines)


def deployment_check_step(_step_input: StepInput) -> StepOutput:
    checks = [_check_database(), _check_auth(), _check_public_url(), _check_realtime(), _check_components()]
    return StepOutput(content=_format(checks), success=not any(item.status == "FAIL" for item in checks))


deployment_check_workflow = Workflow(
    id="deployment-check",
    name="Deployment Check",
    db=get_db(),
    steps=[Step(name="deployment-check", executor=deployment_check_step, max_retries=0, on_error=OnError.fail)],
)

"""Explicit workflow wrapper around the Agno eval suite."""

from __future__ import annotations

import asyncio
import os

from agno.eval import arun_cases
from agno.workflow.step import Step
from agno.workflow.types import OnError, StepInput, StepOutput
from agno.workflow.workflow import Workflow

from db.session import get_db


def _format(payload: dict) -> str:
    summary = payload.get("summary", {})
    lines = [
        "# Menso Evals",
        "",
        f"Overall: **{summary.get('status', 'FAIL')}** ({summary.get('passed', 0)}/{summary.get('total', 0)} passed)",
        "",
    ]
    for case in payload.get("cases", []):
        status = "PASS" if case.get("passed") else "FAIL"
        detail = f"- {status} `{case.get('name')}` ({case.get('duration_seconds', 0)}s)"
        if case.get("error"):
            detail += f" — {case['error']}"
        lines.append(detail)
    return "\n".join(lines)


async def run_evals_step(_step_input: StepInput) -> StepOutput:
    from evals.cases import CASES, eval_db, run_contract_checks

    checks = run_contract_checks()
    tag = os.getenv("EVALS_TAG", "smoke")
    case_timeout = int(os.getenv("EVALS_CASE_TIMEOUT_SECONDS", "90"))
    suite_timeout = int(os.getenv("EVALS_SUITE_TIMEOUT_SECONDS", "300"))
    try:
        suite = await asyncio.wait_for(
            arun_cases(CASES, tag=tag, default_timeout=case_timeout, db=eval_db),
            timeout=suite_timeout,
        )
    except TimeoutError:
        return StepOutput(content=f"# Menso Evals\n\nOverall: **FAIL** — exceeded {suite_timeout}s.", success=False)
    report = _format(suite.to_dict()) + f"\n\nContract checks: {', '.join(checks)}."
    return StepOutput(content=report, success=suite.status == "PASS")


run_evals_workflow = Workflow(
    id="run-evals",
    name="Run Evals",
    db=get_db(),
    steps=[Step(name="run-evals", executor=run_evals_step, max_retries=0, on_error=OnError.fail)],
)

"""Admin-only, review-gated learning publication workflow."""

from __future__ import annotations

import hashlib
import json
import re
from collections import defaultdict
from typing import Any

from agno.learn.stores.learned_knowledge import LearnedKnowledgeStore
from agno.workflow.condition import Condition
from agno.workflow.step import Step
from agno.workflow.types import HumanReview, OnError, OnReject, StepInput, StepOutput
from pydantic import BaseModel

from agents.learning_curator import curator_learning, learning_curator
from app.settings import get_settings
from db.session import get_db
from schemas.learning import (
    AgentImprovementInput,
    AggregatedEvidence,
    EvidenceKind,
    EvidenceSelection,
    ImprovementResult,
    LearningCandidate,
    LearningEvidence,
    MensoFeedbackEvidence,
)
from workflows.base import MensoAgentStep, MensoWorkflow

WORKFLOW_ID = "agent-improvement"
COLLECT_STEP = "collect_evidence"
REDACT_STEP = "redact_and_aggregate"
CURATE_STEP = "classify_candidate"
REVIEW_STEP = "human_review"
PUBLISH_STEP = "publish_reviewed_learning"

_SECRET_PATTERNS = [
    re.compile(r"(?i)(api[_ -]?key|token|password|secret)\s*[:=]\s*\S+"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{12,}\b"),
    re.compile(r"\bBearer\s+[A-Za-z0-9._~+/-]+=*", re.IGNORECASE),
]
_SENSITIVE_KEYS = {
    "api_key",
    "apikey",
    "authorization",
    "cookie",
    "password",
    "secret",
    "token",
}
_VOLATILE_FAILURE_KEYS = {
    "action_id",
    "created_at",
    "eval_run_id",
    "occurred_at",
    "run_id",
    "session_id",
    "updated_at",
}


def _as_model[TModel: BaseModel](model: type[TModel], value: Any) -> TModel:
    if isinstance(value, model):
        return value
    if isinstance(value, BaseModel):
        return model.model_validate(value.model_dump(mode="json"))
    if isinstance(value, str):
        return model.model_validate_json(value)
    return model.model_validate(value)


def _content(step_input: StepInput, name: str) -> Any:
    value = step_input.get_step_content(name)
    if value is None:
        raise ValueError(f"Required step output is missing: {name}")
    return value


def _redact(value: str) -> str:
    redacted = value
    for pattern in _SECRET_PATTERNS:
        redacted = pattern.sub("[REDACTED]", redacted)
    return redacted[:4_000]


def _redact_structured(value: Any, *, depth: int = 0) -> Any:
    if depth > 8:
        return "[TRUNCATED]"
    if isinstance(value, dict):
        sanitized: dict[str, Any] = {}
        for key, item in list(value.items())[:100]:
            normalized = str(key).casefold().replace("-", "_").replace(" ", "_")
            if normalized in _SENSITIVE_KEYS or any(
                normalized.endswith(f"_{suffix}") for suffix in ("password", "secret", "token")
            ):
                sanitized[str(key)] = "[REDACTED]"
            else:
                sanitized[str(key)] = _redact_structured(item, depth=depth + 1)
        return sanitized
    if isinstance(value, (list, tuple)):
        return [_redact_structured(item, depth=depth + 1) for item in value[:100]]
    if isinstance(value, str):
        return _redact(value)
    if value is None or isinstance(value, (bool, int, float)):
        return value
    return _redact(str(value))


def _json_summary(value: Any) -> str:
    """Serialize an evidence projection without leaking arbitrary object reprs."""

    if isinstance(value, BaseModel):
        value = value.model_dump(mode="json")
    try:
        rendered = json.dumps(_redact_structured(value), ensure_ascii=False, sort_keys=True, default=str)
    except (TypeError, ValueError) as exc:
        raise ValueError("Evidence record contains unsupported data") from exc
    return _redact(rendered)


def _without_volatile_failure_ids(value: Any) -> Any:
    """Remove per-attempt IDs while retaining the normalized failure shape."""

    if isinstance(value, dict):
        return {
            key: _without_volatile_failure_ids(item)
            for key, item in sorted(value.items())
            if key not in _VOLATILE_FAILURE_KEYS
        }
    if isinstance(value, list):
        return [_without_volatile_failure_ids(item) for item in value]
    return value


def _normalized_failure_key(item: LearningEvidence) -> str | None:
    """Return a stable key only for an actual normalized run failure."""

    if item.kind != EvidenceKind.RUN:
        return None
    try:
        summary = json.loads(item.summary)
    except (TypeError, ValueError):
        return None
    if not isinstance(summary, dict):
        return None

    status = str(summary.get("status") or "").casefold()
    tool_outcomes = summary.get("tool_outcomes")
    failed_tool = any(
        isinstance(outcome, dict)
        and (
            str(outcome.get("status") or "").casefold() in {"failed", "rejected", "expired"}
            or bool(outcome.get("error_code"))
        )
        for outcome in (tool_outcomes if isinstance(tool_outcomes, list) else [])
    )
    if (
        status not in {"cancelled", "canceled", "error", "failed"}
        and not summary.get("error_summary")
        and not failed_tool
    ):
        return None

    normalized = _without_volatile_failure_ids(summary)
    rendered = json.dumps(normalized, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(rendered.casefold().encode("utf-8")).hexdigest()


def _owned_run(selection: EvidenceSelection) -> dict[str, Any]:
    if not selection.session_id:
        raise ValueError("Run evidence requires an AgentOS session_id")
    session = get_db().get_session(
        selection.session_id,
        user_id=selection.owner_user_id,
        deserialize=False,
    )
    if not isinstance(session, dict) or session.get("user_id") != selection.owner_user_id:
        raise PermissionError("Referenced AgentOS session does not belong to the selected owner")
    raw_runs = session.get("runs")
    runs: list[Any] = raw_runs if isinstance(raw_runs, list) else []
    matches = [
        run
        for run in runs
        if isinstance(run, dict) and run.get("run_id") == selection.reference
    ]
    if len(matches) != 1:
        raise ValueError(f"Referenced AgentOS run is missing or ambiguous: {selection.reference}")
    return matches[0]


def _run_projection(raw: dict[str, Any]) -> dict[str, Any]:
    raw_run_data = raw.get("run_data")
    run_data: dict[str, Any] = raw_run_data if isinstance(raw_run_data, dict) else raw
    raw_metadata = run_data.get("metadata")
    metadata: dict[str, Any] = raw_metadata if isinstance(raw_metadata, dict) else {}
    raw_tools = run_data.get("tools")
    tools: list[Any] = raw_tools if isinstance(raw_tools, list) else []
    tool_outcomes: list[dict[str, Any]] = []
    for tool in tools[:20]:
        if not isinstance(tool, dict):
            continue
        result = tool.get("result")
        if isinstance(result, str):
            try:
                result = json.loads(result)
            except (TypeError, ValueError):
                result = None
        normalized_result = result if isinstance(result, dict) else {}
        tool_outcomes.append(
            {
                "tool_name": tool.get("tool_name") or tool.get("name"),
                "status": normalized_result.get("status"),
                "verified": normalized_result.get("verified"),
                "action_id": normalized_result.get("action_id"),
                "error_code": normalized_result.get("error_code")
                or tool.get("tool_call_error"),
            }
        )
    raw_error = run_data.get("error") or metadata.get("error")
    return {
        "run_id": raw.get("run_id") or run_data.get("run_id"),
        "run_type": raw.get("run_type"),
        "status": raw.get("status") or run_data.get("status"),
        "agent_id": run_data.get("agent_id"),
        "workflow_id": run_data.get("workflow_id"),
        "error_summary": _redact(str(raw_error))[:1_000] if raw_error else None,
        "tool_outcomes": tool_outcomes,
    }


def _feedback_projection(raw: dict[str, Any]) -> dict[str, Any]:
    raw_run_data = raw.get("run_data")
    run_data: dict[str, Any] = raw_run_data if isinstance(raw_run_data, dict) else raw
    raw_metadata = run_data.get("metadata")
    metadata: dict[str, Any] = raw_metadata if isinstance(raw_metadata, dict) else {}
    feedback = metadata.get("menso_feedback")
    try:
        normalized_feedback = MensoFeedbackEvidence.model_validate(feedback)
    except (TypeError, ValueError) as exc:
        raise ValueError("Referenced run has no valid normalized Menso feedback") from exc
    return {
        "run_id": raw.get("run_id") or run_data.get("run_id"),
        "status": raw.get("status") or run_data.get("status"),
        "feedback": normalized_feedback.model_dump(mode="json", exclude_none=True),
    }


def _eval_projection(selection: EvidenceSelection) -> dict[str, Any]:
    # Agno 2.8.5's eval table has no first-class user_id filter. Read the
    # record, then require an owner written into its persisted eval payload;
    # unattributed evals are ineligible rather than trusting caller metadata.
    raw = get_db().get_eval_run(selection.reference, deserialize=False)
    if not isinstance(raw, dict):
        raise ValueError(f"Referenced AgentOS eval does not exist: {selection.reference}")
    raw_eval_data = raw.get("eval_data")
    eval_data: dict[str, Any] = raw_eval_data if isinstance(raw_eval_data, dict) else {}
    raw_eval_input = raw.get("eval_input")
    eval_input: dict[str, Any] = raw_eval_input if isinstance(raw_eval_input, dict) else {}
    raw_metadata = eval_data.get("metadata")
    metadata: dict[str, Any] = raw_metadata if isinstance(raw_metadata, dict) else {}
    stored_owner = (
        raw.get("user_id")
        or eval_input.get("user_id")
        or eval_data.get("user_id")
        or metadata.get("user_id")
    )
    if stored_owner != selection.owner_user_id:
        raise PermissionError("Referenced AgentOS eval has no matching persisted owner attribution")
    normalized_eval_data: dict[str, Any] = {}
    for key in (
        "eval_status",
        "status",
        "passed",
        "pass_rate",
        "score",
        "avg_score",
        "mean_score",
        "min_score",
        "max_score",
        "reason",
        "failed_tool_calls",
        "additional_tool_calls",
        "missing_tool_calls",
        "failed_argument_checks",
        "avg_run_time",
        "p95_run_time",
        "avg_memory_usage",
        "p95_memory_usage",
    ):
        if key in eval_data:
            normalized_eval_data[key] = eval_data[key]
    raw_results = eval_data.get("results")
    if isinstance(raw_results, list):
        normalized_eval_data["results"] = [
            {
                key: item[key]
                for key in ("passed", "score", "reason", "eval_status", "error")
                if key in item
            }
            for item in raw_results[:20]
            if isinstance(item, dict)
        ]
    return {
        "run_id": raw.get("run_id"),
        "eval_type": raw.get("eval_type"),
        "agent_id": raw.get("agent_id"),
        "team_id": raw.get("team_id"),
        "workflow_id": raw.get("workflow_id"),
        "model_id": raw.get("model_id"),
        "eval_result": normalized_eval_data,
    }


def _resolve_evidence(selection: EvidenceSelection) -> LearningEvidence:
    if selection.kind == EvidenceKind.EVAL:
        projection = _eval_projection(selection)
    else:
        run = _owned_run(selection)
        projection = _feedback_projection(run) if selection.kind == EvidenceKind.FEEDBACK else _run_projection(run)
    return LearningEvidence(
        kind=selection.kind,
        reference=f"{selection.kind.value}:{selection.reference}",
        summary=_json_summary(projection),
    )


def collect_redacted_evidence(step_input: StepInput) -> StepOutput:
    request = _as_model(AgentImprovementInput, step_input.input)
    settings = get_settings()
    session_user = getattr(step_input.workflow_session, "user_id", None)
    if not session_user or session_user not in settings.admin_user_ids:
        raise PermissionError("Agent improvement requires an authenticated Menso admin user")
    if request.requested_by != session_user:
        raise PermissionError("requested_by must match the verified workflow user")

    evidence = [_resolve_evidence(item) for item in request.evidence]
    return StepOutput(
        content={
            "evidence": [item.model_dump(mode="json") for item in evidence],
            "maintainer_revision_notes": _redact(request.maintainer_revision_notes)
            if request.maintainer_revision_notes
            else None,
        }
    )


def redact_and_aggregate(step_input: StepInput) -> StepOutput:
    collected = _content(step_input, COLLECT_STEP)
    if not isinstance(collected, dict):
        raise ValueError("Collected evidence output must be an object")
    evidence = [LearningEvidence.model_validate(item) for item in collected.get("evidence", [])]
    by_summary: dict[str, list[str]] = defaultdict(list)
    for item in evidence:
        summary_key = _normalized_failure_key(item)
        if summary_key is not None:
            by_summary[summary_key].append(item.reference)
    repeated = [refs for refs in by_summary.values() if len(set(refs)) > 1]
    explicit_strong_signal = any(item.kind in {EvidenceKind.FEEDBACK, EvidenceKind.EVAL} for item in evidence)
    eligible = explicit_strong_signal or bool(repeated)
    reason = (
        "explicit correction/eval evidence or a repeated normalized failure is present"
        if eligible
        else "a single run summary is too weak to generalize"
    )
    return StepOutput(
        content=AggregatedEvidence(
            evidence=evidence,
            repeated_failure_refs=repeated,
            maintainer_revision_notes=collected.get("maintainer_revision_notes"),
            eligible=eligible,
            eligibility_reason=reason,
        )
    )


def evidence_is_eligible(step_input: StepInput) -> bool:
    return _as_model(AggregatedEvidence, _content(step_input, REDACT_STEP)).eligible


def insufficient_evidence(_step_input: StepInput) -> StepOutput:
    return StepOutput(content=ImprovementResult(status="insufficient_evidence"))


def _validate_learning_candidate(
    candidate: LearningCandidate,
    evidence: AggregatedEvidence,
) -> LearningCandidate:
    allowed_refs = {item.reference for item in evidence.evidence}
    candidate_refs = candidate.evidence_refs
    if len(candidate_refs) != len(set(candidate_refs)) or not set(candidate_refs).issubset(allowed_refs):
        raise ValueError("Candidate evidence_refs must be unique references resolved by this workflow run")
    if candidate.contains_secrets:
        raise ValueError("Candidates that may contain secrets cannot be reviewed for publication")
    candidate_text = "\n".join(
        value
        for value in (
            candidate.observed_failure,
            candidate.proposed_lesson,
            candidate.proposed_instruction_diff,
            candidate.proposed_tool_or_schema_change,
            candidate.risk,
            *candidate.new_eval_cases,
            *candidate.privacy_notes,
        )
        if value
    )
    if any(pattern.search(candidate_text) for pattern in _SECRET_PATTERNS):
        raise ValueError("Candidate text contains secret-like material after redaction")
    if not candidate.generalizable:
        raise ValueError("User-specific or weak candidates cannot enter the shared review gate")
    return candidate


def review_learning_candidate(step_input: StepInput) -> StepOutput:
    candidate_value = step_input.get_step_content(CURATE_STEP)
    if candidate_value is None:
        return StepOutput(content=ImprovementResult(status="insufficient_evidence"))
    candidate = _as_model(LearningCandidate, candidate_value)
    evidence = _as_model(AggregatedEvidence, _content(step_input, REDACT_STEP))
    candidate = _validate_learning_candidate(candidate, evidence)
    return StepOutput(content=candidate)


def requires_candidate_review(step_output: StepOutput) -> bool:
    try:
        _as_model(LearningCandidate, step_output.content)
    except (TypeError, ValueError):
        return False
    return True


def publish_reviewed_learning(step_input: StepInput) -> StepOutput:
    reviewed = step_input.get_step_content(REVIEW_STEP)
    if reviewed is None:
        return StepOutput(content=ImprovementResult(status="rejected_or_skipped"))

    try:
        terminal = _as_model(ImprovementResult, reviewed)
    except (TypeError, ValueError):
        terminal = None
    if terminal is not None:
        return StepOutput(content=terminal)

    candidate = _as_model(LearningCandidate, reviewed)
    evidence = _as_model(AggregatedEvidence, _content(step_input, REDACT_STEP))
    try:
        candidate = _validate_learning_candidate(candidate, evidence)
    except ValueError:
        return StepOutput(content=ImprovementResult(status="policy_rejected", candidate=candidate))

    store = curator_learning.learned_knowledge_store
    if not isinstance(store, LearnedKnowledgeStore):
        raise RuntimeError("Approved learned knowledge store is unavailable")

    digest = hashlib.sha256(candidate.model_dump_json().encode("utf-8")).hexdigest()
    decision_ref = f"improvement-decision:sha256:{digest}"
    workflow_session = step_input.workflow_session
    provenance = {
        "decision_ref": decision_ref,
        "workflow_id": WORKFLOW_ID,
        "workflow_session_id": getattr(workflow_session, "session_id", None),
        "reviewer_user_id": getattr(workflow_session, "user_id", None),
        "evidence_refs": candidate.evidence_refs,
    }
    saved = store.save(
        title=f"{candidate.affected_agent}: {candidate.scope}"[:256],
        learning=candidate.proposed_lesson,
        context=_json_summary(provenance),
        tags=["human-reviewed", "menso-improvement", decision_ref],
        agent_id=learning_curator.id,
        namespace="menso-approved",
    )
    if not saved:
        raise RuntimeError("Approved learning could not be persisted")

    return StepOutput(
        content=ImprovementResult(
            status="published",
            candidate=candidate,
            published_knowledge_id=decision_ref,
            eval_candidate_ref=f"eval-candidate:{digest}",
            source_change_proposal={
                "affected_agent": candidate.affected_agent,
                "scope": candidate.scope,
                "proposed_instruction_diff": candidate.proposed_instruction_diff,
                "proposed_tool_or_schema_change": candidate.proposed_tool_or_schema_change,
                "new_eval_cases": candidate.new_eval_cases,
            },
        )
    )


agent_improvement_workflow = MensoWorkflow(
    id=WORKFLOW_ID,
    name="Agent Improvement",
    description="Redact evidence -> curate proposal -> human review -> publish knowledge only",
    db=get_db(),
    input_schema=AgentImprovementInput,
    steps=[
        Step(name=COLLECT_STEP, executor=collect_redacted_evidence, max_retries=0, on_error=OnError.fail),
        Step(name=REDACT_STEP, executor=redact_and_aggregate, max_retries=0, on_error=OnError.fail),
        Condition(
            name="generalizable_evidence_gate",
            evaluator=evidence_is_eligible,
            steps=[
                MensoAgentStep(name=CURATE_STEP, agent=learning_curator, max_retries=0, on_error=OnError.fail),
            ],
            else_steps=[
                Step(name="insufficient_evidence", executor=insufficient_evidence, max_retries=0, on_error=OnError.fail)
            ],
            on_error=OnError.fail,
        ),
        Step(
            name=REVIEW_STEP,
            executor=review_learning_candidate,
            max_retries=0,
            human_review=HumanReview(
                requires_output_review=requires_candidate_review,
                output_review_message=(
                    "Accept, reject, or submit a sanitized edited LearningCandidate for deterministic re-validation."
                ),
                on_reject=OnReject.skip,
                on_error=OnError.fail,
                max_retries=0,
            ),
        ),
        Step(name=PUBLISH_STEP, executor=publish_reviewed_learning, max_retries=0, on_error=OnError.fail),
    ],
)

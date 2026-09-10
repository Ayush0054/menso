"""Private learning profile and reviewed improvement proposal contracts."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime
from enum import StrEnum
from typing import Literal

from agno.learn.schemas import UserProfile
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


@dataclass
class MensoUserProfile(UserProfile):
    """Stable, scoped preferences only; never persist secrets or raw messages."""

    communication_preferences: list[str] = field(default_factory=list)
    scheduling_preferences: list[str] = field(default_factory=list)
    accessibility_preferences: list[str] = field(default_factory=list)


class EvidenceKind(StrEnum):
    RUN = "run"
    FEEDBACK = "feedback"
    EVAL = "eval"


class EvidenceSelection(BaseModel):
    """An admin-selected, ownership-bound AgentOS record.

    The caller selects records but never supplies the evidence text. The
    workflow resolves the reference from Postgres and derives a redacted,
    bounded summary from the stored record.
    """

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    kind: EvidenceKind
    reference: str = Field(min_length=1, max_length=480)
    owner_user_id: str = Field(min_length=1, max_length=256)
    session_id: str | None = Field(default=None, min_length=1, max_length=512)

    @model_validator(mode="after")
    def require_session_for_run_evidence(self) -> EvidenceSelection:
        if self.kind in {EvidenceKind.RUN, EvidenceKind.FEEDBACK} and not self.session_id:
            raise ValueError("run and feedback evidence require an owned AgentOS session_id")
        return self


class LearningEvidence(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    kind: EvidenceKind
    reference: str = Field(min_length=1, max_length=512)
    summary: str = Field(min_length=1, max_length=4_000)


class MensoFeedbackEvidence(BaseModel):
    """Normalized feedback persisted by a trusted backend producer."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    rating: Literal["positive", "negative"] | None = None
    category: Literal["accuracy", "routing", "safety", "tone", "tool_outcome", "other"]
    correction_summary: str | None = Field(default=None, min_length=1, max_length=1_000)
    normalized_outcome: Literal["succeeded", "failed", "rejected", "expired"] | None = None
    contains_third_party_content: Literal[False] = False

    @model_validator(mode="after")
    def require_signal(self) -> MensoFeedbackEvidence:
        if self.rating is None and self.correction_summary is None and self.normalized_outcome is None:
            raise ValueError("Feedback requires a rating, correction, or normalized outcome")
        return self


class AgentImprovementInput(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    evidence: list[EvidenceSelection] = Field(min_length=1, max_length=100)
    requested_by: str = Field(min_length=1, max_length=256)
    requested_at: datetime
    maintainer_revision_notes: str | None = Field(default=None, max_length=4_000)

    @field_validator("requested_at")
    @classmethod
    def normalize_time(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("requested_at must include a timezone")
        return value.astimezone(UTC)


class LearningCandidate(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    affected_agent: str = Field(min_length=1, max_length=128)
    scope: str = Field(min_length=1, max_length=256)
    evidence_refs: list[str] = Field(min_length=1, max_length=100)
    observed_failure: str = Field(min_length=1, max_length=4_000)
    proposed_lesson: str = Field(min_length=1, max_length=8_000)
    proposed_instruction_diff: str | None = Field(default=None, max_length=8_000)
    proposed_tool_or_schema_change: str | None = Field(default=None, max_length=8_000)
    new_eval_cases: list[str] = Field(default_factory=list, max_length=20)
    privacy_notes: list[str] = Field(default_factory=list, max_length=20)
    risk: str = Field(min_length=1, max_length=4_000)
    contains_secrets: bool = False
    generalizable: bool = False


class AggregatedEvidence(BaseModel):
    model_config = ConfigDict(extra="forbid")

    evidence: list[LearningEvidence]
    repeated_failure_refs: list[list[str]] = Field(default_factory=list)
    maintainer_revision_notes: str | None = None
    eligible: bool
    eligibility_reason: str


class ImprovementResult(BaseModel):
    model_config = ConfigDict(extra="forbid")

    status: str
    candidate: LearningCandidate | None = None
    published_knowledge_id: str | None = None
    eval_candidate_ref: str | None = None
    source_change_proposal: dict[str, str | list[str] | None] | None = None

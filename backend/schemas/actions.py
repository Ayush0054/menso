"""Generic contracts for client-executed, security-sensitive actions."""

from __future__ import annotations

from datetime import UTC, datetime
from enum import StrEnum
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class ActionStatus(StrEnum):
    OPENED = "opened"
    FOCUSED = "focused"
    INSERTED = "inserted"
    ACTIVATED = "activated"
    REJECTED = "rejected"
    EXPIRED = "expired"
    FAILED = "failed"


class ApplicationActionTarget(BaseModel):
    """Semantic application/window/control target selected by the Mac client."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    kind: Literal["application"] = "application"
    bundle_id: str = Field(min_length=1, max_length=512)
    window_title: str | None = Field(default=None, min_length=1, max_length=1_024)
    element_role: str | None = Field(default=None, min_length=1, max_length=128)
    element_label: str | None = Field(default=None, min_length=1, max_length=1_024)


class ActionBinding(BaseModel):
    """Binds a CUA action to one workflow step and one idempotency window."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    workflow_id: str = Field(min_length=1, max_length=128)
    step_id: str = Field(min_length=1, max_length=128)
    expected_tool_name: str = Field(min_length=1, max_length=128)
    idempotency_key: str = Field(min_length=16, max_length=256)
    expires_at: datetime

    @field_validator("expires_at")
    @classmethod
    def require_timezone(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("expires_at must include a timezone")
        return value.astimezone(UTC)


class ExternalExecutionResult(BaseModel):
    """Typed evidence returned by the trusted macOS executor.

    ``verified`` means the client observed the requested UI state and checked it
    against the server-issued binding. It is evidence, not authorization.
    """

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    action_id: str = Field(min_length=1, max_length=256)
    status: ActionStatus
    target: ApplicationActionTarget
    content_hash: str | None = Field(default=None, pattern=r"^[a-f0-9]{64}$")
    verified: bool = False
    evidence_ref: str | None = Field(default=None, max_length=512)
    error_code: str | None = Field(default=None, max_length=128)
    occurred_at: datetime = Field(default_factory=lambda: datetime.now(UTC))

    @field_validator("occurred_at")
    @classmethod
    def normalize_time(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("occurred_at must include a timezone")
        return value.astimezone(UTC)


class ContinueRequest(BaseModel):
    """Documentation schema for the two non-interchangeable continue contracts."""

    model_config = ConfigDict(extra="forbid")

    endpoint_kind: Literal["agent", "workflow"]
    run_id: str = Field(min_length=1, max_length=512)
    session_id: str = Field(min_length=1, max_length=512)
    tools: list[dict[str, Any]] | None = Field(default=None, min_length=1)
    step_requirements: list[dict[str, Any]] | None = Field(default=None, min_length=1)

    @model_validator(mode="after")
    def require_endpoint_specific_envelope(self) -> ContinueRequest:
        if self.endpoint_kind == "agent":
            if self.tools is None or self.step_requirements is not None:
                raise ValueError("Agent continuation requires tools only")
        elif self.step_requirements is None or self.tools is not None:
            raise ValueError("Workflow continuation requires step_requirements only")
        return self


def continuation_route_for(endpoint_kind: Literal["agent", "workflow"], resource_id: str, run_id: str) -> str:
    """Return the matching AgentOS continue endpoint without merging contracts."""

    if endpoint_kind == "agent":
        return f"/agents/{resource_id}/runs/{run_id}/continue"
    return f"/workflows/{resource_id}/runs/{run_id}/continue"

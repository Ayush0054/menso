"""Typed results from the Menso task agent to GPT-Live."""

from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from schemas.actions import ExternalExecutionResult


class DelegateToMensoRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    task: str = Field(min_length=1, max_length=4_000)
    context_refs: list[Annotated[str, Field(min_length=1, max_length=512)]] = Field(max_length=20)
    operation_hint: Literal["open_ended", "desktop_action"]


class DelegateToMensoResult(BaseModel):
    model_config = ConfigDict(extra="forbid")

    status: Literal["completed", "requires_external_action", "rejected"]
    spoken_summary: str = Field(min_length=1, max_length=1_000)
    display_payload: dict[str, object] | None = None
    action_receipts: list[ExternalExecutionResult] = Field(default_factory=list, max_length=20)
    run_id: str | None = Field(default=None, min_length=1, max_length=512)
    continuation_kind: Literal["agent", "workflow"] | None = None
    continuation_resource_id: str | None = Field(default=None, min_length=1, max_length=128)

    @model_validator(mode="after")
    def validate_continuation_metadata(self) -> DelegateToMensoResult:
        metadata = (self.run_id, self.continuation_kind, self.continuation_resource_id)
        if any(value is not None for value in metadata) and not all(value is not None for value in metadata):
            raise ValueError("Continuation metadata must include run, kind, and resource together")
        if self.status == "requires_external_action" and not all(value is not None for value in metadata):
            raise ValueError("External-action results require complete continuation metadata")
        return self

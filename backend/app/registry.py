"""Least-privilege AgentOS Studio registry."""

from typing import Any

from agno.registry import Registry

from agents.models import default_model
from db.session import get_db
from schemas.actions import continuation_route_for


def route_component_type(request: str) -> str:
    """Choose a coarse component type without exposing a privileged builder."""

    lowered = request.lower()
    if any(word in lowered for word in ("approval", "pipeline", "schedule", "ordered", "workflow")):
        return "workflow"
    return "agent"


def describe_continuation_contract(endpoint_kind: str) -> str:
    """Return the required body field for a direct Agent or Workflow pause."""

    if endpoint_kind == "agent":
        return "Agent continue: preserve tool call IDs and submit the updated tools form field."
    if endpoint_kind == "workflow":
        return "Workflow continue: preserve the append-only envelope and submit the full step_requirements form field."
    raise ValueError("endpoint_kind must be agent or workflow")


class MensoSafeRegistry(Registry):
    """Registry that refuses AgentOS's automatic Toolkit publication.

    Agno walks every registered Agent and Workflow step during AgentOS
    construction and calls ``registry.add_tool`` for their toolkits. That is
    useful for generic Studio editing, but would expose model-visible action
    declarations as mutable registry entries. Menso publishes no tool entries; code-defined
    Agents and Workflows retain their directly attached tool instances.
    """

    def add_tool(self, tool: Any) -> None:
        del tool


registry = MensoSafeRegistry(
    name="Menso Safe Registry",
    models=[default_model()],
    dbs=[get_db()],
    functions=[route_component_type, describe_continuation_contract, continuation_route_for],
)

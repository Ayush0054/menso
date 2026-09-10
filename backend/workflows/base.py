"""Pinned Agno Workflow adapters shared by Menso workflows."""

from __future__ import annotations

from copy import copy
from typing import Any

from agno.workflow.condition import Condition
from agno.workflow.step import Step
from agno.workflow.workflow import Workflow


class MensoAgentStep(Step):
    """Forward the persisted Workflow subject to an Agent/Team executor.

    Agno 2.8.5 passes ``Workflow.user_id`` (normally unset on the request-local
    copy) into Step executors instead of the authenticated run/session subject.
    The WorkflowSession was created with that verified subject, so use it as the
    executor attribution without mutating a shared Agent or Workflow singleton.
    """

    @staticmethod
    def _trusted_user_id(step_input: Any, kwargs: dict[str, Any]) -> str | None:
        workflow_session = kwargs.get("workflow_session") or getattr(step_input, "workflow_session", None)
        user_id = getattr(workflow_session, "user_id", None)
        return user_id if isinstance(user_id, str) and user_id else None

    def execute(self, step_input: Any, *args: Any, **kwargs: Any) -> Any:
        trusted_user_id = self._trusted_user_id(step_input, kwargs)
        if trusted_user_id is not None:
            kwargs["user_id"] = trusted_user_id
        return super().execute(step_input, *args, **kwargs)

    async def aexecute(self, step_input: Any, *args: Any, **kwargs: Any) -> Any:
        trusted_user_id = self._trusted_user_id(step_input, kwargs)
        if trusted_user_id is not None:
            kwargs["user_id"] = trusted_user_id
        return await super().aexecute(step_input, *args, **kwargs)

    def execute_stream(self, step_input: Any, *args: Any, **kwargs: Any) -> Any:
        trusted_user_id = self._trusted_user_id(step_input, kwargs)
        if trusted_user_id is not None:
            kwargs["user_id"] = trusted_user_id
        yield from super().execute_stream(step_input, *args, **kwargs)

    async def aexecute_stream(self, step_input: Any, *args: Any, **kwargs: Any) -> Any:
        trusted_user_id = self._trusted_user_id(step_input, kwargs)
        if trusted_user_id is not None:
            kwargs["user_id"] = trusted_user_id
        async for event in super().aexecute_stream(step_input, *args, **kwargs):
            yield event


class MensoWorkflow(Workflow):
    """Keep reviewed Condition HITL/error policy on Agno request copies.

    Agno 2.8.5's ``Workflow._deep_copy_single_step`` reconstructs a
    ``Condition`` without forwarding its ``human_review``/``on_error`` config,
    changing explicit ``OnError.fail`` policy to the default ``skip``. AgentOS
    deep-copies code-defined workflows for every request, so Menso restores the
    immutable configuration on that copy. Re-check this adapter on Agno upgrades.
    """

    def _deep_copy_single_step(self, step: Any) -> Any:
        copied = super()._deep_copy_single_step(step)
        if isinstance(step, MensoAgentStep) and isinstance(copied, Step):
            # The pinned implementation reconstructs every Step as the base
            # class. Reconstruct the small subclass from that already-isolated
            # copy so verified Workflow user forwarding survives the request.
            copied = MensoAgentStep(
                name=copied.name,
                agent=copied.agent,
                team=copied.team,
                executor=copied.executor,
                workflow=copied.workflow,
                step_id=copied.step_id,
                description=copied.description,
                max_retries=copied.max_retries,
                skip_on_failure=copied.skip_on_failure,
                strict_input_validation=copied.strict_input_validation,
                add_workflow_history=copied.add_workflow_history,
                num_history_runs=copied.num_history_runs,
                human_review=copy(copied.human_review),
            )
        if isinstance(step, Condition) and isinstance(copied, Condition):
            copied.human_review = copy(step.human_review)
            copied.requires_confirmation = step.requires_confirmation
            copied.confirmation_message = step.confirmation_message
            copied.on_reject = step.on_reject
            copied.on_error = step.on_error
        return copied

    def update_agents_and_teams_session_info(self) -> None:
        """Recursively mark nested executors as Workflow members.

        Agno 2.8.5 handles top-level Steps only. Menso uses Conditions for
        fail-closed branching, so recurse into their children before execution.
        """

        super().update_agents_and_teams_session_info()

        def mark(item: Any) -> None:
            if isinstance(item, Step):
                executor = item.active_executor
                if hasattr(executor, "workflow_id"):
                    executor.workflow_id = self.id
                for member in getattr(executor, "members", None) or []:
                    if hasattr(member, "workflow_id"):
                        member.workflow_id = self.id
                return
            for child in getattr(item, "steps", None) or []:
                mark(child)
            for child in getattr(item, "else_steps", None) or []:
                mark(child)
            for child in getattr(item, "choices", None) or []:
                mark(child)

        if not self.steps or callable(self.steps):
            return
        steps = self.steps.steps if hasattr(self.steps, "steps") else self.steps
        for item in steps or []:
            mark(item)

    def continue_run(self, *args: Any, **kwargs: Any) -> Any:
        # AgentOS resolves a fresh Workflow copy for continuation as well as
        # initial execution, so restore nested membership before routing the
        # persisted executor requirement back to its Agent.
        self.update_agents_and_teams_session_info()
        return super().continue_run(*args, **kwargs)

    async def acontinue_run(self, *args: Any, **kwargs: Any) -> Any:
        self.update_agents_and_teams_session_info()
        return await super().acontinue_run(*args, **kwargs)

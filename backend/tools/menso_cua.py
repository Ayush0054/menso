"""App-agnostic Agno Toolkit declarations for client-executed CUA actions."""

from __future__ import annotations

from collections.abc import Callable, Sequence
from typing import Any, Literal

from agno.tools import Toolkit


class MensoCuaToolkit(Toolkit):
    """Register semantic computer-use actions as Agno external execution.

    The Toolkit owns only model-visible schemas. Every implementation lives in
    the authenticated macOS client, where policy, target binding, execution,
    and verification are enforced. Coordinates, raw clicks/keys, screenshots,
    selectors, shell commands, and the CUA MCP surface are intentionally absent.

    The Toolkit is intentionally application-agnostic. New semantic functions
    require an explicit backend schema and a matching reviewed Mac verifier;
    callers cannot inject arbitrary functions at construction time.
    """

    CORE_TOOLS = (
        "open_application",
        "focus_window",
        "insert_text",
        "activate_control",
    )

    def __init__(
        self,
        *,
        include_tools: Sequence[str] | None = None,
        name: str = "menso_cua",
    ) -> None:
        declared: list[Callable[..., Any]] = [
            self.open_application,
            self.focus_window,
            self.insert_text,
            self.activate_control,
        ]
        declared_names = [action.__name__ for action in declared]
        if len(set(declared_names)) != len(declared_names):
            raise ValueError("Menso CUA action names must be unique")

        selected = declared_names if include_tools is None else list(include_tools)
        unknown = set(selected).difference(declared_names)
        if unknown:
            raise ValueError(f"Unknown Menso CUA tools: {sorted(unknown)}")
        if not selected:
            raise ValueError("Menso CUA Toolkit requires at least one semantic action")

        super().__init__(
            name=name,
            tools=declared,
            include_tools=selected,
            external_execution_required_tools=selected,
        )

    def open_application(self, bundle_id: str) -> str:
        """Request native approval to open or foreground an installed app.

        Call with ``bundle_id`` from the current native application list. Do not
        wait for a local binding or user approval before proposing this call.
        The Mac creates the binding and approval card from the proposal; only
        after approval does it execute and verify the app is frontmost.
        """

        raise RuntimeError("open_application is external-execution only")

    def focus_window(self, bundle_id: str, pid: int, window_title: str) -> str:
        """Request native approval to focus one already-known window.

        Propose the call using the exact current native target, without waiting
        for a separate preparation step. The Mac resolves and reviews the
        app/window target before execution and verifies the resulting
        focused window. Partial or ambiguous title matches fail closed.
        """

        raise RuntimeError("focus_window is external-execution only")

    def insert_text(
        self,
        bundle_id: str,
        pid: int,
        text: str,
        window_title: str,
        field_role: Literal["AXTextField", "AXTextArea", "AXSearchField"],
        field_label: str,
    ) -> str:
        """Request native approval to insert text without submitting it.

        Propose the call using the current native focused-field metadata.
        The Mac binds the application/window/field, presents approval, and
        verifies the inserted draft after approved execution.
        """

        raise RuntimeError("insert_text is external-execution only")

    def activate_control(
        self,
        bundle_id: str,
        pid: int,
        window_title: str,
        control_role: Literal[
            "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton"
        ],
        control_label: str,
        expected_state: str,
    ) -> str:
        """Request native approval to activate one known semantic UI control.

        Propose the call using the current native focused-control metadata.
        The Mac treats this as potentially irreversible and requires human
        review before execution, then verifies the expected result.
        """

        raise RuntimeError("activate_control is external-execution only")

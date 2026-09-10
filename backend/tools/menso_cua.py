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
        """Open or foreground an installed application by bundle identifier.

        The Mac must match ``bundle_id`` to app-owned launch authority and
        verify that the requested application is running and frontmost.
        """

        raise RuntimeError("open_application is external-execution only")

    def focus_window(self, bundle_id: str, pid: int, window_title: str) -> str:
        """Focus one already-known application window without editing content.

        The Mac must resolve an exact app/window target and verify the resulting
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
        """Insert text into one trusted native field without submitting it.

        This is a draft-like action. The Mac must bind the application/window/
        field to trusted UI context and verify the inserted content.
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
        """Activate one semantic UI control and verify its expected result.

        The Mac treats this as potentially irreversible: an explicit policy
        rule or client-side human review is required before execution.
        """

        raise RuntimeError("activate_control is external-execution only")

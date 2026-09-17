"""Prevent Agno's automatic registry collection from publishing desktop tools."""

from typing import Any

from agno.registry import Registry


class MensoSafeRegistry(Registry):
    def add_tool(self, tool: Any) -> None:
        del tool


registry = MensoSafeRegistry(name="Menso")

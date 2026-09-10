"""Centralized model constructors; agents remain process singletons."""

from __future__ import annotations

import os

from agno.models.openai import OpenAIResponses


def default_model() -> OpenAIResponses:
    return OpenAIResponses(id=os.getenv("MENSO_MODEL_ID", "gpt-5.6-sol"))


def executor_model() -> OpenAIResponses:
    return OpenAIResponses(id=os.getenv("MENSO_EXECUTOR_MODEL_ID", os.getenv("MENSO_MODEL_ID", "gpt-5.6-sol")))

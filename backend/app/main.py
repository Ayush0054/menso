"""Fail-closed AgentOS composition root for the Menso backend."""

from __future__ import annotations

import os
from contextlib import asynccontextmanager
from pathlib import Path

from agno.os import AgentOS
from agno.os.config import AuthorizationConfig
from agno.utils.log import log_info
from fastapi import FastAPI

from agents.menso import menso_agent
from app.auth_context import router as auth_context_router
from app.live import router as live_router
from app.registry import registry
from app.settings import get_settings, resolve_jwks_file
from db.session import get_db

settings = get_settings()

base_app = FastAPI(title="Menso AgentOS", version="0.1.0")
base_app.include_router(auth_context_router)
base_app.include_router(live_router)


@asynccontextmanager
async def lifespan(_app):  # type: ignore[no-untyped-def]
    log_info("Menso AgentOS startup")
    try:
        yield
    finally:
        log_info("Menso AgentOS shutdown")


authorization_config = AuthorizationConfig(
    verification_keys=[settings.jwt_verification_key] if settings.jwt_verification_key else None,
    jwks_file=resolve_jwks_file(settings),
    algorithm=settings.jwt_algorithm,
    verify_audience=True,
    audience=settings.os_id,
    admin_scope="agent_os:admin",
    user_isolation=True,
)

agent_os = AgentOS(
    id=settings.os_id,
    name="Menso AgentOS",
    description="Menso voice tasks with approved, locally verified Mac actions.",
    db=get_db(),
    agents=[menso_agent],
    registry=registry,
    knowledge=[],
    config=str(Path(__file__).parent / "config.yaml"),
    base_app=base_app,
    on_route_conflict="error",
    authorization=settings.auth_enabled,
    authorization_config=authorization_config,
    tracing=True,
    lifespan=lifespan,
)

app = agent_os.get_app()


if __name__ == "__main__":
    reload_enabled = settings.runtime_env == "dev" and os.getenv("AGNO_DEBUG", "false").lower() == "true"
    agent_os.serve(app="app.main:app", reload=reload_enabled)

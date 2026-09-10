"""Authenticated minting of short-lived OpenAI Realtime client secrets."""

from __future__ import annotations

import hashlib
import hmac
from time import time
from typing import Any

import httpx
from fastapi import APIRouter, HTTPException, Request, Response, status
from pydantic import BaseModel, ConfigDict, Field

from app.auth_context import require_verified_jwt_context
from app.settings import get_settings

router = APIRouter(prefix="/menso/realtime", tags=["menso-realtime"])
_CLIENT_SECRETS_URL = "https://api.openai.com/v1/realtime/client_secrets"
_MAX_CLIENT_SECRET_TTL_SECONDS = 600


class RealtimeClientSecretResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    value: str = Field(min_length=1, max_length=8_192)
    expires_at: int = Field(gt=0)
    session: dict[str, Any]


def _safety_identifier(user_id: str, salt: str) -> str:
    digest = hmac.new(salt.encode("utf-8"), user_id.encode("utf-8"), hashlib.sha256).hexdigest()
    return f"menso_{digest}"


def _require_realtime_principal(request: Request) -> str:
    user_id, verified_scopes = require_verified_jwt_context(request)
    scopes = set(verified_scopes)
    if "agent_os:admin" not in scopes and "realtime:connect" not in scopes:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Missing realtime:connect scope")
    return user_id


@router.post("/client-secret", response_model=RealtimeClientSecretResponse)
async def create_realtime_client_secret(request: Request, response: Response) -> RealtimeClientSecretResponse:
    """Mint a constrained ephemeral token without exposing the standard API key."""

    user_id = _require_realtime_principal(request)
    response.headers["Cache-Control"] = "no-store, max-age=0"
    response.headers["Pragma"] = "no-cache"
    settings = get_settings()
    if not settings.openai_api_key:
        raise HTTPException(status_code=503, detail="Realtime provider is not configured")
    if not settings.safety_identifier_salt or len(settings.safety_identifier_salt) < 32:
        raise HTTPException(status_code=503, detail="Realtime safety identifier salt is not configured")

    session = {
        "type": "realtime",
        "model": settings.openai_realtime_model,
        "instructions": (
            "You are Menso's low-latency voice transport. Handle conversational acknowledgements directly. "
            "For durable reasoning or product actions, call delegate_to_menso. Never invent app targets, "
            "workflows, approvals, action receipts, or claim an action completed before its returned result."
        ),
        "audio": {"output": {"voice": settings.openai_realtime_voice}},
        "reasoning": {"effort": settings.openai_realtime_reasoning_effort},
        "tools": [
            {
                "type": "function",
                "name": "delegate_to_menso",
                "description": "Delegate durable reasoning or a product operation to the authenticated Menso runtime.",
                "parameters": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": {
                        "task": {"type": "string", "minLength": 1, "maxLength": 4000},
                        "context_refs": {
                            "type": "array",
                            "items": {"type": "string", "minLength": 1, "maxLength": 512},
                            "maxItems": 20,
                        },
                        "operation_hint": {"type": "string", "enum": ["open_ended", "desktop_action"]},
                    },
                    "required": ["task", "context_refs", "operation_hint"],
                },
            }
        ],
        "tool_choice": "auto",
    }
    headers = {
        "Authorization": f"Bearer {settings.openai_api_key}",
        "Content-Type": "application/json",
        "OpenAI-Safety-Identifier": _safety_identifier(user_id, settings.safety_identifier_salt),
    }
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(15.0, connect=5.0)) as client:
            provider_response = await client.post(_CLIENT_SECRETS_URL, headers=headers, json={"session": session})
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail="Realtime provider request failed") from exc

    if provider_response.status_code >= 400:
        raise HTTPException(
            status_code=502,
            detail=f"Realtime provider rejected the request ({provider_response.status_code})",
        )
    try:
        payload = provider_response.json()
        provider_session = payload["session"]
        if not isinstance(provider_session, dict):
            raise ValueError("missing provider session")
        if (
            provider_session.get("type") != "realtime"
            or provider_session.get("model") != settings.openai_realtime_model
        ):
            raise ValueError("provider changed the constrained session type or model")
        provider_audio = provider_session.get("audio")
        if not isinstance(provider_audio, dict):
            raise ValueError("provider omitted the constrained audio configuration")
        provider_output = provider_audio.get("output")
        if not isinstance(provider_output, dict) or provider_output.get("voice") != settings.openai_realtime_voice:
            raise ValueError("provider changed the constrained output voice")
        provider_tools = provider_session.get("tools")
        if not isinstance(provider_tools, list) or len(provider_tools) != 1:
            raise ValueError("provider changed the delegate-only tool set")
        provider_tool = provider_tools[0]
        if (
            not isinstance(provider_tool, dict)
            or provider_tool.get("type") != "function"
            or provider_tool.get("name") != "delegate_to_menso"
        ):
            raise ValueError("provider changed the delegate-only tool set")
        expires_at = payload["expires_at"]
        now = int(time())
        if (
            not isinstance(expires_at, int)
            or isinstance(expires_at, bool)
            or expires_at <= now
            or expires_at > now + _MAX_CLIENT_SECRET_TTL_SECONDS
        ):
            raise ValueError("provider returned a non-ephemeral client secret")

        client_secret = RealtimeClientSecretResponse.model_validate(
            {
                "value": payload["value"],
                "expires_at": expires_at,
                "session": provider_session,
            }
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise HTTPException(status_code=502, detail="Realtime provider returned an invalid response") from exc
    return client_secret

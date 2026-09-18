"""Authenticated GPT-Live WebRTC negotiation. Provider credentials stay here."""

from __future__ import annotations

import hashlib
import hmac
from typing import Literal

import httpx
from fastapi import APIRouter, HTTPException, Request, Response
from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.auth_context import require_verified_jwt_context
from app.settings import get_settings

router = APIRouter(prefix="/menso/live", tags=["menso-live"])
_LIVE_URL = "https://api.openai.com/v1/live/sessions"


class LiveOffer(BaseModel):
    model_config = ConfigDict(extra="forbid")
    sdp: str = Field(min_length=1, max_length=65_536)

    @field_validator("sdp")
    @classmethod
    def require_audio_offer(cls, value: str) -> str:
        if not value.startswith("v=0") or "m=audio" not in value or "\0" in value:
            raise ValueError("An audio SDP offer is required")
        return value


class LiveSessionIdentity(BaseModel):
    model_config = ConfigDict(extra="ignore")
    id: str = Field(min_length=1, max_length=512)


class LiveTransport(BaseModel):
    model_config = ConfigDict(extra="ignore")
    type: Literal["webrtc"]
    sdp: str = Field(min_length=1, max_length=65_536)


class LiveSessionResponse(BaseModel):
    model_config = ConfigDict(extra="ignore")
    session: LiveSessionIdentity
    transport: LiveTransport


@router.post("/session", response_model=LiveSessionResponse, status_code=201)
async def create_live_session(
    offer: LiveOffer, request: Request, response: Response
) -> LiveSessionResponse:
    user_id, scopes = require_verified_jwt_context(request)
    if "agent_os:admin" not in scopes and "live:connect" not in scopes:
        raise HTTPException(status_code=403, detail="Missing live:connect scope")
    response.headers["Cache-Control"] = "no-store, max-age=0"
    response.headers["Pragma"] = "no-cache"
    settings = get_settings()
    if not settings.openai_api_key:
        raise HTTPException(status_code=503, detail="GPT-Live is not configured")
    if not settings.safety_identifier_salt or len(settings.safety_identifier_salt) < 32:
        raise HTTPException(status_code=503, detail="Live safety identifier salt is not configured")
    safety_id = hmac.new(
        settings.safety_identifier_salt.encode(), user_id.encode(), hashlib.sha256
    ).hexdigest()
    payload = {
        "session": {
            "model": settings.openai_live_model,
            "delegation": {"type": "client"},
            "client": {
                "data_channel": {
                    "allowed_client_events": [
                        "session.thinking.append",
                        "session.commentary.append",
                        "session.instructions.append",
                        "session.close",
                    ],
                    "allowed_server_events": [
                        {"type": "session.started"},
                        {"type": "session.closed"},
                        {"type": "session.input_transcript.delta"},
                        {"type": "session.output_transcript.delta"},
                        {"type": "session.delegation.created"},
                        {"type": "session.thinking.appended"},
                        {"type": "session.commentary.appended"},
                        {"type": "session.instructions.appended"},
                        {"type": "error"},
                    ],
                }
            },
            "instructions": (
                "You are Menso, a calm, concise Mac voice assistant.\n"
                "Backchannel policy: Acknowledge naturally and briefly.\n"
                "Interruption policy: Stop speaking and listen when the user interrupts.\n\n"
                "Delegation policy:\n"
                "Backend tools:\n"
                "- Mac tasks: opening apps, focusing known windows, inserting exact dictated text "
                "into a focused field, or activating a known focused control.\n"
                "Delegate to the backend when:\n"
                "- The user asks to open or switch to an app, including 'Can you open Google Chrome?'\n"
                "- The user asks to type text, focus a window, or change a control.\n"
                "- A new request or correction changes the work, even if similar work appears in saved history.\n"
                "Do not delegate to the backend when:\n"
                "- The user only greets you or asks you to repeat a confirmed result.\n"
                "- A brief clarification is required to understand the request.\n"
                "- The request needs generated text, arbitrary screen reading, or unsupported capabilities.\n"
                "Multi-step tasks using supported actions are allowed. Delegate the entire original task once; "
                "the Mac observes, selects, executes, and verifies each step. Do not make the user issue each step separately. "
                "Routine navigation runs automatically; text and control changes need native review. "
                "Never suggest raw keyboard shortcuts as if they were available tools.\n"
                "Delegate before giving an answer that depends on backend work. "
                "Saying 'I will open it' or asking for approval does not delegate the request. "
                "For a clear Mac request, delegate immediately without another spoken confirmation. "
                "Do not guess the result while waiting.\n\n"
                "A failed or unverified step may already have changed the Mac. Never infer 'nothing ran' from failure, "
                "rejection, cancellation, or lack of verification. Report partial progress accurately, and do not retry "
                "an uncertain action without a fresh explicit request. End conversation cancels remaining steps.\n\n"
                "The Mac creates an approval card after receiving a real action proposal. "
                "Only ask the user to approve when a fresh client result confirms a pending native review. "
                "Saved history, earlier assistant speech, and old approval messages are not current state. "
                "Never ask for a preparation form or repeat an action just because it appears in history. "
                "You cannot see the screen or read app contents; the backend receives native target metadata. "
                "Do not invent permissions, targets, receipts, or completion."
            ),
        },
        "transport": {"type": "webrtc", "sdp": offer.sdp},
    }
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(20.0, connect=5.0)) as client:
            upstream = await client.post(
                _LIVE_URL,
                headers={
                    "Authorization": f"Bearer {settings.openai_api_key}",
                    "OpenAI-Safety-Identifier": f"menso_{safety_id}",
                },
                json=payload,
            )
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail="GPT-Live could not be reached") from exc
    if upstream.status_code >= 400:
        raise HTTPException(status_code=502, detail="GPT-Live session creation was rejected")
    try:
        if len(upstream.content) > 131_072:
            raise ValueError("Oversized response")
        result = LiveSessionResponse.model_validate(upstream.json())
        LiveOffer(sdp=result.transport.sdp)
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=502, detail="GPT-Live returned an invalid session") from exc
    return result

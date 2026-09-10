"""Returns only authentication metadata verified by AgentOS middleware."""

from __future__ import annotations

from fastapi import APIRouter, HTTPException, Request, Response, status
from pydantic import BaseModel, ConfigDict, Field

router = APIRouter(prefix="/menso/auth", tags=["menso-auth"])


class AuthenticatedContextResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    user_id: str = Field(min_length=1, max_length=512)
    scopes: list[str] = Field(default_factory=list, max_length=256)


def require_verified_jwt_context(request: Request) -> tuple[str, list[str]]:
    """Return only a JWT subject/scopes verified by AgentOS middleware.

    AgentOS also authenticates service-account PATs and its internal scheduler
    token. Those credentials intentionally have no decoded ``claims`` object
    and must not mint a user Realtime token or become the Mac user's identity.
    """

    authenticated = bool(getattr(request.state, "authenticated", False))
    user_id = getattr(request.state, "user_id", None)
    claims = getattr(request.state, "claims", None)
    raw_scopes = getattr(request.state, "scopes", []) or []
    if (
        not authenticated
        or not isinstance(user_id, str)
        or not user_id
        or not isinstance(claims, dict)
        or claims.get("sub") != user_id
    ):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Verified JWT subject required",
        )
    if not isinstance(raw_scopes, (list, tuple, set, frozenset)):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Verified JWT scopes required",
        )

    scopes = sorted(
        scope for scope in raw_scopes if isinstance(scope, str) and 0 < len(scope) <= 256
    )[:256]
    return user_id, scopes


@router.get("/context", response_model=AuthenticatedContextResponse)
async def authenticated_context(request: Request, response: Response) -> AuthenticatedContextResponse:
    """Bind the signed client to the JWT subject already verified by AgentOS."""

    user_id, scopes = require_verified_jwt_context(request)
    response.headers["Cache-Control"] = "no-store, max-age=0"
    response.headers["Pragma"] = "no-cache"
    return AuthenticatedContextResponse(user_id=user_id, scopes=scopes)

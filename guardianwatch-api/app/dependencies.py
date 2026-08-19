"""Reusable FastAPI dependencies — auth guards and the ML model registry."""
from __future__ import annotations

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.models.user import User
from app.security import decode_access_token

_bearer_scheme = HTTPBearer(
    auto_error=True,
    description="Backend JWT obtained from POST /auth/token (not the raw Firebase ID token).",
)


async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer_scheme),
    db: AsyncSession = Depends(get_db),
) -> User:
    """
    Every endpoint except /health, /auth/token, and the docs depends on
    this. Matches `ApiService._headers()` on the Dart side, which attaches
    `Authorization: Bearer <jwt>` to every call once `exchangeToken` has run.
    """
    claims = decode_access_token(credentials.credentials)
    user_id = claims.get("sub")
    if not user_id:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid session token"
        )

    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        # Valid JWT, but the account behind it is gone — force re-auth
        # rather than let requests silently operate on a ghost user.
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Account not found — please sign in again",
        )
    return user


async def get_current_premium_user(user: User = Depends(get_current_user)) -> User:
    """Gate for premium-only insight content (sleep apnea, AFib, etc.)."""
    if not user.premium:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="This feature requires a GuardianWrist Premium subscription",
        )
    return user


def get_model_registry(request: Request):
    """
    The `ModelRegistry` is loaded once at startup (see `main.py` lifespan)
    and stored on `app.state`. Depending on `Request` here — rather than
    importing a module-level singleton directly in every ml/ function —
    keeps the ML layer trivially testable (tests can swap in a fake
    registry via dependency overrides).
    """
    return request.app.state.models

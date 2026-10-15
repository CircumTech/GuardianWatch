"""Reusable FastAPI dependencies — auth guards and the ML model registry."""
from __future__ import annotations

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.models.user import User
from app.models.admin_user import AdminUser
from app.security import decode_access_token, decode_admin_token

_bearer_scheme = HTTPBearer(
    auto_error=True,
    description="Backend JWT obtained from POST /auth/token (not the raw Firebase ID token).",
)
_admin_bearer_scheme = HTTPBearer(
    auto_error=True,
    description="Admin JWT obtained from POST /admin/auth/login. Not interchangeable with a customer token.",
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

async def get_current_user_optional(
    credentials: HTTPAuthorizationCredentials | None = Depends(
        _admin_bearer_scheme
    ),
    db: AsyncSession = Depends(get_db),
) -> User | None:
    """
    Returns the authenticated User, or None if no valid credentials were
    provided.

    Uses the SAME token decoder as `get_current_user`. An invalid or
    expired token returns None rather than raising — for endpoints where
    auth is optional, a bad token is treated the same as no token, and
    the endpoint falls back to its guest path.

    Endpoints that REQUIRE auth must use `get_current_user`, not this
    dependency — an invalid token there should be a 401, not silently
    downgraded to guest access.
    """
    if credentials is None:
        return None

    try:
        claims = decode_access_token(credentials.credentials)
    except HTTPException:
        # Invalid / expired / malformed token. Treat as guest.
        return None

    user_id = claims.get("sub")
    if not user_id:
        return None

    result = await db.execute(select(User).where(User.id == user_id))
    return result.scalar_one_or_none()

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


async def get_current_admin(
    credentials: HTTPAuthorizationCredentials = Depends(_admin_bearer_scheme),
    db: AsyncSession = Depends(get_db),
) -> AdminUser:
    """
    The admin-panel equivalent of get_current_user — deliberately its own
    function, its own bearer scheme, and its own token decoder
    (decode_admin_token, a different secret entirely — see security.py).
    Every admin router depends on this and nothing else grants it; a
    customer's JWT from POST /auth/token will not decode here no matter
    what claims it carries, because it wasn't signed with
    ADMIN_JWT_SECRET_KEY in the first place.
    """
    claims = decode_admin_token(credentials.credentials)
    admin_id = claims.get("sub")
    if not admin_id:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid admin session")

    admin = await db.get(AdminUser, admin_id)
    if admin is None or not admin.is_active:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Admin account not found or deactivated",
        )
    return admin

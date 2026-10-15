"""POST /auth/token — the one endpoint that runs before a JWT exists."""
import logging

from fastapi import APIRouter, Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.database import get_db
from app.rate_limit import limiter
from app.schemas.auth import TokenExchangeRequest, TokenExchangeResponse
from app.schemas.user import UserOut
from app.services import auth_service

router = APIRouter(prefix="/auth", tags=["auth"])
settings = get_settings()

logger = logging.getLogger("guardianwrist.auth")


@router.post("/token", response_model=TokenExchangeResponse)
@limiter.limit(settings.RATE_LIMIT_AUTH)
async def exchange_token(
    request: Request,  # required by @limiter.limit to key on client IP
    body: TokenExchangeRequest,
    db: AsyncSession = Depends(get_db),
):
    """
    Exchanges a Firebase ID token for this API's own JWT.

    Called by `ApiService.exchangeToken` on the Dart side immediately
    after Firebase sign-in (and again after any 401 that triggers a
    Firebase token refresh). Rate-limited tighter than the API default
    since it's the one endpoint reachable without a valid backend
    session.
    """
    user, token, expires_in = await auth_service.exchange_firebase_token(
        db, body.id_token
    )

    logger.info(
        "Token exchanged [request_id=%s user=%s]",
        getattr(request.state, "request_id", "-"),
        user.id,
    )

    return TokenExchangeResponse(
        access_token=token,
        expires_in=expires_in,
        user=UserOut.model_validate(user),
    )
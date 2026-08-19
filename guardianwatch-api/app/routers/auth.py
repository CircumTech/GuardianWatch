"""POST /auth/token — the one endpoint that runs before a JWT exists."""
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


@router.post("/token", response_model=TokenExchangeResponse)
@limiter.limit(settings.RATE_LIMIT_AUTH)
async def exchange_token(
    request: Request,  # required by @limiter.limit to key on client IP — unused otherwise
    body: TokenExchangeRequest,
    db: AsyncSession = Depends(get_db),
):
    """
    Matches `ApiService.exchangeToken` — takes the Firebase ID token the
    Dart app already has from `FirebaseAuth`, verifies it, and returns
    this API's own JWT for every subsequent call. Rate-limited tighter
    than the API default since it's the one endpoint reachable without a
    valid session.
    """
    user, token, expires_in = await auth_service.exchange_firebase_token(db, body.id_token)
    return TokenExchangeResponse(
        access_token=token,
        expires_in=expires_in,
        user=UserOut.model_validate(user),
    )

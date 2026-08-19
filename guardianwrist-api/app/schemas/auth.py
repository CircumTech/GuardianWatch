from pydantic import BaseModel

from app.schemas.user import UserOut


class TokenExchangeRequest(BaseModel):
    """Body for POST /auth/token — matches `AuthService._exchangeForBackendJwt`
    in auth_service.dart, which sends `{'id_token': idToken}`."""
    id_token: str


class TokenExchangeResponse(BaseModel):
    """
    The Dart client only reads `data['access_token']` (see
    `ApiService.exchangeToken`), so `access_token` is the one field that
    *must* be here. `token_type`, `expires_in`, and `user` are extra and
    harmless — useful for anything else calling this API (Swagger, a future
    web client) without risking the existing app.
    """
    access_token: str
    token_type: str = "bearer"
    expires_in: int
    user: UserOut

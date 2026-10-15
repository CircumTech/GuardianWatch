from pydantic import BaseModel, Field

from app.schemas.user import UserOut


class TokenExchangeRequest(BaseModel):
    """Body for POST /auth/token.

    Matches `lib/services/api_service.dart::exchangeToken`, which sends
    `{'id_token': <firebase id token>}`.

    Bounds:
    - `min_length=100` rejects obvious garbage before it reaches the
      Firebase Admin SDK. Real Firebase ID tokens are ~800-2000 chars.
    - `max_length=4096` bounds header/payload size.
    """

    id_token: str = Field(
        ...,
        min_length=100,
        max_length=4096,
        description=(
            "Firebase ID token obtained from "
            "FirebaseAuth.instance.currentUser.getIdToken()."
        ),
    )


class TokenExchangeResponse(BaseModel):
    """Response for POST /auth/token.

    The Dart client only reads `data['access_token']` (see
    `ApiService.exchangeToken`), so `access_token` is the one field that
    *must* be here. `token_type`, `expires_in`, and `user` are extras —
    useful for the Swagger UI and the future web client without risking
    the mobile app.
    """

    access_token: str
    token_type: str = "bearer"
    expires_in: int
    user: UserOut
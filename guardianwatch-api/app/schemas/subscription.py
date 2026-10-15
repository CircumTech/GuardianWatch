import datetime as dt

from pydantic import BaseModel, Field


class VerifyReceiptRequest(BaseModel):
    """
    Body for POST /subscription/verify.

    Matches `IAPService._verifyAndActivate` after the claims-policy
    review, which sends all three fields:

        _api.verifySubscription(
            receipt: verificationData,
            productId: purchase.productID,
            platform: _platformName(),
        )

    `platform` is a required string, not a Literal — mobile's
    `_platformName()` can return any of `android`, `ios`, `macos`,
    `windows`, `linux`, `fuchsia`. The backend only knows how to verify
    Apple (ios/macos) and Google (android); anything else returns an
    `invalid` response rather than a 422.
    """
    receipt: str = Field(..., min_length=1, max_length=65536)
    product_id: str = Field(..., min_length=1, max_length=255)
    platform: str | None = None


class SubscriptionVerificationOut(BaseModel):
    """
    Response for both POST /subscription/verify and
    GET /subscription/status.

    Field names match `SubscriptionVerification.fromJson` in
    `api_service.dart` **exactly**. This is not a stylistic choice —
    mobile reads `valid` and `active` as required booleans, and treats
    a missing field as `false`. Any change to these names silently
    breaks the entire premium-entitlement system.
    """

    # ── Read by mobile ───────────────────────────────────────────────
    valid: bool
    active: bool
    product_id: str | None = None
    platform: str | None = None
    expires_at: dt.datetime | None = None
    auto_renewing: bool | None = None
    message: str | None = None

    # ── Debug / human-readable ───────────────────────────────────────
    # Not read by mobile, but useful for logging and the admin panel.
    transaction_id: str | None = None
    status: str  # "active" | "expired" | "invalid"


# Retained as an alias so the router's existing import keeps working
# during the transition. Remove once the router is updated.
VerifyReceiptResponse = SubscriptionVerificationOut
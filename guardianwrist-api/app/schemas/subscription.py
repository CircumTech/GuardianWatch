import datetime as dt
from typing import Literal

from pydantic import BaseModel


class VerifyReceiptRequest(BaseModel):
    """
    Body for POST /subscription/verify. `iap_service.dart::_onPurchaseUpdate`
    calls `_api.verifyReceipt(p.verificationData.serverVerificationData,
    p.productID)`, which only ever sends `receipt` + `product_id` — no
    platform flag, even though `defaultTargetPlatform` is available right
    there in the same file (see `openManageSubscriptions`).

    `platform` is kept optional here so this works against the app exactly
    as it ships today (the service tries Apple then Google when it's
    absent — see `services/receipt_service.py`). Recommended follow-up:
    add one line to `_onPurchaseUpdate` to send
    `defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android'` —
    it's a trivial, backward-compatible change that skips the guesswork.
    """
    receipt: str
    product_id: str
    platform: Literal["ios", "android"] | None = None


class VerifyReceiptResponse(BaseModel):
    status: Literal["active", "expired", "invalid"]
    premium: bool
    expires_at: dt.datetime | None = None

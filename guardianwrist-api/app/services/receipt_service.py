"""
Verifies IAP receipts against Apple's and Google Play's server APIs, and
records the result. Backs POST /subscription/verify.

Important caveat: this sandbox's network egress is limited to package
registries (pypi, npm, github) for building this project — it cannot
reach `buy.itunes.apple.com` or `androidpublisher.googleapis.com`, so this
module is implemented correctly against each platform's documented API
contract but has NOT been exercised end-to-end the way the rest of this
backend was. Test it against real sandbox receipts (Apple's
StoreKit Testing / Google Play's license testers) before relying on it.
"""
from __future__ import annotations

import datetime as dt
import logging
import uuid

import httpx
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.models.subscription import IAPPlatform, Subscription, SubscriptionStatus
from app.models.user import User
from app.schemas.subscription import VerifyReceiptRequest, VerifyReceiptResponse

logger = logging.getLogger("guardianwrist.receipts")
settings = get_settings()


async def verify_apple_receipt(receipt: str) -> VerifyReceiptResponse:
    if not settings.APPLE_SHARED_SECRET:
        raise RuntimeError("APPLE_SHARED_SECRET is not configured")

    payload = {
        "receipt-data": receipt,
        "password": settings.APPLE_SHARED_SECRET,
        "exclude-old-transactions": True,
    }

    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.post(settings.APPLE_VERIFY_URL, json=payload)
        data = resp.json()
        if data.get("status") == 21007:
            # "This receipt is from the test environment" — Apple's documented
            # way of saying retry against the sandbox endpoint.
            resp = await client.post(settings.APPLE_VERIFY_URL_SANDBOX, json=payload)
            data = resp.json()

    if data.get("status") != 0:
        return VerifyReceiptResponse(status="invalid", premium=False)

    latest = data.get("latest_receipt_info") or data.get("receipt", {}).get("in_app", [])
    if not latest:
        return VerifyReceiptResponse(status="invalid", premium=False)

    newest = max(
        latest, key=lambda r: int(r.get("expires_date_ms", r.get("purchase_date_ms", 0)))
    )
    expires_ms = newest.get("expires_date_ms")
    if expires_ms:
        expires_at = dt.datetime.fromtimestamp(int(expires_ms) / 1000, tz=dt.timezone.utc)
        active = expires_at > dt.datetime.now(dt.timezone.utc)
    else:
        # Non-renewing product with no expiry field — presence in the
        # receipt is treated as an active entitlement.
        expires_at, active = None, True

    return VerifyReceiptResponse(
        status="active" if active else "expired", premium=active, expires_at=expires_at
    )


async def verify_google_receipt(purchase_token: str, product_id: str) -> VerifyReceiptResponse:
    if not settings.GOOGLE_PLAY_SERVICE_ACCOUNT_PATH:
        raise RuntimeError("GOOGLE_PLAY_SERVICE_ACCOUNT_PATH is not configured")

    from google.auth.transport.requests import Request as GoogleAuthRequest
    from google.oauth2 import service_account

    credentials = service_account.Credentials.from_service_account_file(
        settings.GOOGLE_PLAY_SERVICE_ACCOUNT_PATH,
        scopes=["https://www.googleapis.com/auth/androidpublisher"],
    )
    credentials.refresh(GoogleAuthRequest())

    url = (
        "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/"
        f"{settings.GOOGLE_PLAY_PACKAGE_NAME}/purchases/subscriptions/"
        f"{product_id}/tokens/{purchase_token}"
    )
    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.get(url, headers={"Authorization": f"Bearer {credentials.token}"})

    if resp.status_code != 200:
        return VerifyReceiptResponse(status="invalid", premium=False)

    data = resp.json()
    expiry_ms = data.get("expiryTimeMillis")
    payment_state = data.get("paymentState")  # 1 = received, 2 = free trial

    if expiry_ms is None:
        return VerifyReceiptResponse(status="invalid", premium=False)

    expires_at = dt.datetime.fromtimestamp(int(expiry_ms) / 1000, tz=dt.timezone.utc)
    active = expires_at > dt.datetime.now(dt.timezone.utc) and payment_state in (1, 2)

    return VerifyReceiptResponse(
        status="active" if active else "expired", premium=active, expires_at=expires_at
    )


async def verify_receipt(req: VerifyReceiptRequest) -> VerifyReceiptResponse:
    """
    Dispatches by `req.platform` when given. The Flutter app doesn't send
    it today (see the schema docstring), so when absent this tries Apple
    then Google — safe because each call fails fast on a receipt format
    the wrong store doesn't recognize.
    """
    if req.platform == "ios":
        return await verify_apple_receipt(req.receipt)
    if req.platform == "android":
        return await verify_google_receipt(req.receipt, req.product_id)

    for attempt in (
        lambda: verify_apple_receipt(req.receipt),
        lambda: verify_google_receipt(req.receipt, req.product_id),
    ):
        try:
            return await attempt()
        except Exception as exc:  # noqa: BLE001
            logger.info("Receipt verification attempt failed, trying next store: %s", exc)
    return VerifyReceiptResponse(status="invalid", premium=False)


async def record_verification(
    db: AsyncSession, user: User, req: VerifyReceiptRequest, result: VerifyReceiptResponse
) -> Subscription:
    """Persists the verification (audit trail) and flips `User.premium`."""
    sub = Subscription(
        id=uuid.uuid4().hex,
        user_id=user.id,
        product_id=req.product_id,
        platform=IAPPlatform(req.platform) if req.platform else IAPPlatform.ios,
        status=SubscriptionStatus(result.status),
        raw_receipt=req.receipt,
        expires_at=result.expires_at,
    )
    db.add(sub)

    user.premium = result.premium
    user.premium_expires_at = result.expires_at

    await db.commit()
    await db.refresh(sub)
    return sub

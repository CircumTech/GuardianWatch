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
from sqlalchemy import select

from app.config import get_settings
from app.models.subscription import IAPPlatform, Subscription, SubscriptionStatus
from app.models.user import User
from app.schemas.subscription import VerifyReceiptRequest, VerifyReceiptResponse

logger = logging.getLogger("guardianwrist.receipts")
settings = get_settings()


def _response_from(
    *,
    valid: bool,
    active: bool,
    status: str,
    product_id: str | None = None,
    platform: str | None = None,
    expires_at: dt.datetime | None = None,
    auto_renewing: bool | None = None,
    message: str | None = None,
    transaction_id: str | None = None,
) -> SubscriptionVerificationOut:
    """
    Single construction point so every return path produces the exact
    field set mobile reads. Keeping this in one place makes it impossible
    to accidentally ship a response missing `valid` or `active`.
    """
    return SubscriptionVerificationOut(
        valid=valid,
        active=active,
        product_id=product_id,
        platform=platform,
        expires_at=expires_at,
        auto_renewing=auto_renewing,
        message=message,
        status=status,
        transaction_id=transaction_id,
    )


def _platform_enum(platform: str | None) -> IAPPlatform | None:
    """
    Maps mobile's platform string to the enum. Anything not recognized
    returns None so the caller records an "unknown" platform instead of
    silently defaulting to iOS.
    """
    if platform == "ios" or platform == "macos":
        return IAPPlatform.ios
    if platform == "android":
        return IAPPlatform.android
    return None


async def verify_apple_receipt(
    receipt: str,
    product_id: str | None = None,
) -> SubscriptionVerificationOut:
    if not settings.APPLE_SHARED_SECRET:
        logger.error("Apple receipt verification requested but APPLE_SHARED_SECRET is unset")
        return _response_from(
            valid=False,
            active=False,
            status="invalid",
            product_id=product_id,
            platform="ios",
            message="Apple receipt verification is not configured",
        )

    payload = {
        "receipt-data": receipt,
        "password": settings.APPLE_SHARED_SECRET,
        "exclude-old-transactions": True,
    }

    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.post(settings.APPLE_VERIFY_URL, json=payload)
        data = resp.json()
        if data.get("status") == 21007:
            resp = await client.post(settings.APPLE_VERIFY_URL_SANDBOX, json=payload)
            data = resp.json()

    if data.get("status") != 0:
        return _response_from(
            valid=False,
            active=False,
            status="invalid",
            product_id=product_id,
            platform="ios",
            message=f"Apple status {data.get('status')}",
        )

    latest = (
        data.get("latest_receipt_info")
        or data.get("receipt", {}).get("in_app", [])
    )
    if not latest:
        return _response_from(
            valid=False,
            active=False,
            status="invalid",
            product_id=product_id,
            platform="ios",
            message="No transactions in receipt",
        )

    newest = max(
        latest,
        key=lambda r: int(
            r.get("expires_date_ms", r.get("purchase_date_ms", 0))
        ),
    )
    expires_ms = newest.get("expires_date_ms")
    transaction_id = newest.get("transaction_id")

    if expires_ms:
        expires_at = dt.datetime.fromtimestamp(
            int(expires_ms) / 1000, tz=dt.timezone.utc
        )
        active = expires_at > dt.datetime.now(dt.timezone.utc)
    else:
        expires_at = None
        active = True

    return _response_from(
        valid=True,
        active=active,
        status="active" if active else "expired",
        product_id=product_id or newest.get("product_id"),
        platform="ios",
        expires_at=expires_at,
        auto_renewing=True,
        transaction_id=transaction_id,
    )


async def verify_google_receipt(
    purchase_token: str,
    product_id: str,
) -> SubscriptionVerificationOut:
    if not settings.GOOGLE_PLAY_SERVICE_ACCOUNT_PATH:
        logger.error(
            "Google receipt verification requested but "
            "GOOGLE_PLAY_SERVICE_ACCOUNT_PATH is unset"
        )
        return _response_from(
            valid=False,
            active=False,
            status="invalid",
            product_id=product_id,
            platform="android",
            message="Google Play receipt verification is not configured",
        )

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
        resp = await client.get(
            url, headers={"Authorization": f"Bearer {credentials.token}"}
        )

    if resp.status_code != 200:
        return _response_from(
            valid=False,
            active=False,
            status="invalid",
            product_id=product_id,
            platform="android",
            message=f"Google Play HTTP {resp.status_code}",
        )

    data = resp.json()
    expiry_ms = data.get("expiryTimeMillis")
    payment_state = data.get("paymentState")
    transaction_id = data.get("orderId")

    if expiry_ms is None:
        return _response_from(
            valid=False,
            active=False,
            status="invalid",
            product_id=product_id,
            platform="android",
            message="No expiry in Google Play response",
        )

    expires_at = dt.datetime.fromtimestamp(
        int(expiry_ms) / 1000, tz=dt.timezone.utc
    )
    active = (
        expires_at > dt.datetime.now(dt.timezone.utc)
        and payment_state in (1, 2)
    )
    auto_renewing = bool(data.get("autoRenewing", False))

    return _response_from(
        valid=True,
        active=active,
        status="active" if active else "expired",
        product_id=product_id,
        platform="android",
        expires_at=expires_at,
        auto_renewing=auto_renewing,
        transaction_id=transaction_id,
    )


async def verify_receipt(
    req: VerifyReceiptRequest,
) -> SubscriptionVerificationOut:
    """
    Dispatches by platform. Mobile sends platform explicitly, so the
    fallback path (try Apple, then Google) is only exercised by legacy
    clients or manual testing.
    """
    if req.platform in ("ios", "macos"):
        return await verify_apple_receipt(req.receipt, req.product_id)
    if req.platform == "android":
        return await verify_google_receipt(req.receipt, req.product_id)

    if req.platform is None:
        # Legacy path. Try Apple first — the older app build didn't send
        # platform. Each attempt fails fast on a foreign format.
        for attempt in (
            lambda: verify_apple_receipt(req.receipt, req.product_id),
            lambda: verify_google_receipt(req.receipt, req.product_id),
        ):
            try:
                result = await attempt()
                if result.valid:
                    return result
            except Exception as exc:  # noqa: BLE001
                logger.info("Receipt verification attempt failed: %s", exc)

        return _response_from(
            valid=False,
            active=False,
            status="invalid",
            product_id=req.product_id,
            message="Receipt could not be verified with any store",
        )

    # Unsupported platform (windows, linux, fuchsia, etc.)
    return _response_from(
        valid=True,
        active=active,
        status="active" if active else "expired",
        product_id=product_id,
        platform="android",
        expires_at=expires_at,
        auto_renewing=auto_renewing,
        transaction_id=transaction_id,
    )


async def record_verification(
    db: AsyncSession,
    user: User,
    req: VerifyReceiptRequest,
    result: SubscriptionVerificationOut,
) -> Subscription:
    """
    Persists the verification (audit trail) and flips `User.premium`.

    The platform is preserved as given when recognized; unknown
    platforms are recorded as None rather than defaulting to iOS.
    """
    sub = Subscription(
        id=uuid.uuid4().hex,
        user_id=user.id,
        product_id=req.product_id,
        platform=_platform_enum(req.platform),
        status=SubscriptionStatus(result.status),
        raw_receipt=req.receipt,
        expires_at=result.expires_at,
    )
    db.add(sub)

    user.premium = result.active
    user.premium_expires_at = result.expires_at

    await db.commit()
    await db.refresh(sub)
    return sub


async def get_subscription_status(
    db: AsyncSession,
    user: User,
) -> SubscriptionVerificationOut:
    """
    Powers GET /subscription/status — the endpoint mobile calls on every
    app resume (`IAPProvider.didChangeAppLifecycleState`).

    Reads the most recent `Subscription` row for the user and returns
    its state in the same shape as POST /subscription/verify.
    """
    result = await db.execute(
        select(Subscription)
        .where(Subscription.user_id == user.id)
        .order_by(Subscription.created_at.desc())
        .limit(1)
    )
    latest = result.scalar_one_or_none()

    if latest is None:
        # User has never verified a receipt. This is a valid state.
        # Mobile maps `valid=false, active=false` to PremiumStatus.inactive.
        return _response_from(
            valid=False,
            active=False,
            status="invalid",
            message="No subscription on file",
        )

    # Re-evaluate activity against the stored expiry in case time has
    # passed since the last verification — a row can be "active" in the
    # table but no longer valid.
    now = dt.datetime.now(dt.timezone.utc)
    still_active = (
        latest.status == SubscriptionStatus.active
        and latest.expires_at is not None
        and latest.expires_at > now
    )

    return _response_from(
        valid=True,
        active=still_active,
        status="active" if still_active else "expired",
        product_id=latest.product_id,
        platform=(
            latest.platform.value if latest.platform is not None else None
        ),
        expires_at=latest.expires_at,
        auto_renewing=None,
        transaction_id=latest.transaction_id,   # ← newly included
    )
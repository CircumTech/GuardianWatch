from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.subscription import VerifyReceiptRequest, VerifyReceiptResponse, SubscriptionVerificationOut
from app.services import receipt_service

router = APIRouter(prefix="/subscription", tags=["subscription"])


@router.post("/verify", response_model=VerifyReceiptResponse)
async def verify_subscription(
    body: VerifyReceiptRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    Matches `ApiService.verifyReceipt` — the Dart client only checks for
    HTTP 200, so any handled outcome (active/expired/invalid) returns 200;
    only a genuine server error should ever surface as non-200 here.
    """
    result = await receipt_service.verify_receipt(body)
    await receipt_service.record_verification(db, user, body, result)
    return result


router.get("/status", response_model=SubscriptionVerificationOut)
async def get_subscription_status(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    Returns the current subscription state for the signed-in user.

    Called by `IAPService.refreshEntitlement()` on every app resume
    (via `IAPProvider.didChangeAppLifecycleState`) to reconcile
    entitlements that changed while the app was closed — expirations,
    renewals, refunds, family-sharing revocations.

    Returns `{valid: false, active: false, status: "invalid"}` when the
    user has never verified a receipt, which mobile maps to
    `PremiumStatus.inactive`.
    """
    return await receipt_service.get_subscription_status(db, user)
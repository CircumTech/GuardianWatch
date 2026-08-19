from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.subscription import VerifyReceiptRequest, VerifyReceiptResponse
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

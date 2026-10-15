"""
Server-to-server callbacks from Stripe. This is the ONLY place an order
is trusted to actually be paid — never the browser redirect back from
Checkout, which an attacker (or just a flaky connection) could hit
without a real payment having gone through.
"""
from fastapi import APIRouter, Depends, Header, Request
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.services import payment_service

router = APIRouter(prefix="/webhooks", tags=["webhooks"])


@router.post("/stripe", status_code=200)
async def stripe_webhook(
    request: Request,
    stripe_signature: str = Header(..., alias="Stripe-Signature"),
    db: AsyncSession = Depends(get_db),
):
    payload = await request.body()
    event = payment_service.verify_webhook_signature(payload, stripe_signature)

    if event["type"] == "checkout.session.completed":
        await payment_service.handle_checkout_completed(db, event)

    return {"received": True}

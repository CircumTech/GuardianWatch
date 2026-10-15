"""
Stripe integration.

Two responsibilities:
  - Creating a Stripe Checkout Session for a pending order.
  - Turning a verified `checkout.session.completed` webhook into an
    order status update.

Deliberately uses Stripe Checkout (a Stripe-hosted payment page) rather
than building a custom card form against the Payment Intents API
directly — this app's server and frontend never see, handle, or store a
raw card number, which keeps it entirely out of PCI-DSS scope beyond
the lightest tier (SAQ A).

Configuration: STRIPE_SECRET_KEY and STRIPE_WEBHOOK_SECRET must be set.
Without them, checkout creation and webhook verification raise a clear
503 rather than a confusing Stripe SDK error.

CONCURRENCY

  The Stripe Python SDK is synchronous. Every API call from an async
  FastAPI context is wrapped in `asyncio.to_thread` to avoid blocking
  the event loop for the duration of the Stripe round trip. If the
  installed SDK is version 8.0+, the `.create_async()` variants should
  be used instead — they're cheaper than spawning a thread.
"""
from __future__ import annotations

import asyncio
import datetime as dt
import logging

import stripe
from fastapi import HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.models.order import Order, OrderStatus
from app.services import order_service

logger = logging.getLogger("guardianwrist.payments")

# Bounds how long an abandoned checkout holds the reserved stock. Stripe
# accepts 30 minutes to 24 hours; 30 minutes is the shortest allowed and
# keeps the "customer forgot and the item shows out of stock" window
# tight. A scheduled job is still needed to release the stock when the
# session expires — that's not in this module.
_CHECKOUT_SESSION_TTL = dt.timedelta(minutes=30)


def _require_stripe_configured() -> None:
    """
    Ensures `STRIPE_SECRET_KEY` is set and the SDK's module-level
    `stripe.api_key` is up to date.

    `get_settings()` is called fresh on every invocation rather than
    captured at import time, so an environment change (or a test that
    monkeypatches the setting) is picked up. `@lru_cache` makes this
    cheap.
    """
    settings = get_settings()
    if not settings.STRIPE_SECRET_KEY:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Payments are not configured on this deployment yet.",
        )
    stripe.api_key = settings.STRIPE_SECRET_KEY


# ─────────────────────────────────────────────────────────────────────────
# Checkout session
# ─────────────────────────────────────────────────────────────────────────


async def create_checkout_session(db: AsyncSession, order_id: str) -> str:
    """
    Returns the Stripe-hosted checkout URL for an existing pending order.

    If the order already has a live Stripe session (from a previous
    call), that session is reused rather than creating a duplicate. This
    covers the common case where the customer refreshes the checkout
    page or double-taps the pay button before the redirect completes.

    Raises 503 if Stripe is not configured, 404 if the order does not
    exist, 400 if the order is not pending, and 500 if Stripe returns a
    session without a URL.
    """
    _require_stripe_configured()
    settings = get_settings()

    order = await order_service.get_order(db, order_id)
    if order is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Order not found",
        )
    if order.status != OrderStatus.pending:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Order is already {order.status.value}, not payable.",
        )

    # ── Reuse an existing open session if one exists ─────────────────
    if order.stripe_checkout_session_id:
        try:
            existing = await asyncio.to_thread(
                stripe.checkout.Session.retrieve,
                order.stripe_checkout_session_id,
            )
            if existing.status == "open" and existing.url:
                logger.info(
                    "Reusing open Stripe session %s for order %s",
                    existing.id,
                    order.id,
                )
                return existing.url
        except stripe.StripeError as exc:
            # Session expired, was deleted, or Stripe API hiccup. Log
            # and fall through to creating a fresh one.
            logger.info(
                "Could not reuse existing session %s for order %s: %r",
                order.stripe_checkout_session_id,
                order.id,
                exc,
            )

    # ── Create a new session ─────────────────────────────────────────
    session = await asyncio.to_thread(
        stripe.checkout.Session.create,
        mode="payment",
        payment_method_types=["card"],
        line_items=[
            {
                "price_data": {
                    "currency": order.currency,
                    "unit_amount": order.unit_price_cents,
                    "product_data": {"name": order.product.name},
                },
                "quantity": order.quantity,
            }
        ],
        customer_email=order.customer_email,
        client_reference_id=order.id,
        metadata={"order_id": order.id},
        # 30 minutes from now — bounds how long the reserved stock sits
        # in a pending state if the customer abandons checkout.
        expires_at=int(
            (dt.datetime.now(dt.timezone.utc) + _CHECKOUT_SESSION_TTL).timestamp()
        ),
        # Note: no email in the URL. The email was leaking into browser
        # history, access logs, and the Referer header of any third-party
        # asset the confirmation page loads. The frontend re-supplies it
        # via the lookup query parameter.
        success_url=(
            f"{settings.FRONTEND_URL}/order-confirmation"
            f"?order_id={order.id}"
        ),
        cancel_url=(
            f"{settings.FRONTEND_URL}/checkout"
            f"?order_id={order.id}&cancelled=true"
        ),
    )

    if not session.url:
        logger.error(
            "Stripe returned a session without a URL: session=%s order=%s",
            session.id,
            order.id,
        )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Could not create payment session.",
        )

    # Persist the session id so a subsequent call can reuse it.
    order.stripe_checkout_session_id = session.id
    await db.commit()

    logger.info(
        "Stripe session created: session=%s order=%s amount=%s %s",
        session.id,
        order.id,
        order.total_cents,
        order.currency,
    )
    return session.url


# ─────────────────────────────────────────────────────────────────────────
# Webhook verification
# ─────────────────────────────────────────────────────────────────────────


def verify_webhook_signature(payload: bytes, sig_header: str) -> stripe.Event:
    """
    Verifies a Stripe webhook signature and returns the parsed event.

    Raises 503 if the webhook secret is unset, 400 if the signature is
    invalid. `stripe.Webhook.construct_event` performs the HMAC check —
    it must see the raw request body, not a re-serialized version, so
    the router must pass `await request.body()` unchanged.
    """
    settings = get_settings()
    if not settings.STRIPE_WEBHOOK_SECRET:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Webhook not configured",
        )

    try:
        return stripe.Webhook.construct_event(
            payload, sig_header, settings.STRIPE_WEBHOOK_SECRET
        )
    except (ValueError, stripe.SignatureVerificationError) as exc:
        logger.warning("Stripe webhook signature verification failed: %r", exc)
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid webhook signature",
        ) from exc


# ─────────────────────────────────────────────────────────────────────────
# Event handling
# ─────────────────────────────────────────────────────────────────────────


async def handle_checkout_completed(db: AsyncSession, event: stripe.Event) -> None:
    """
    Handles `checkout.session.completed` — transitions the order from
    `pending` to `paid`.

    Idempotent by construction: Stripe delivers webhooks at-least-once,
    so this function may run multiple times for the same event. The
    status check ensures the second delivery is a no-op.
    """
    session = event["data"]["object"]

    # `metadata` may be missing or explicitly null depending on how the
    # session was created.
    metadata = session.get("metadata") or {}
    order_id = metadata.get("order_id") or session.get("client_reference_id")
    if not order_id:
        # Not one of ours — a Stripe account can host many
        # integrations, and the webhook endpoint only knows about its
        # own metadata schema. Silently ignore.
        return

    order = await order_service.get_order(db, order_id)
    if order is None:
        logger.warning(
            "Webhook references unknown order %s (session=%s)",
            order_id,
            session.get("id"),
        )
        return

    # ── Verify the payment is actually complete ──────────────────────
    # `completed` for a card payment implies `payment_status == "paid"`,
    # but async payment methods can fire this event with `unpaid`.
    # Defensive check.
    payment_status = session.get("payment_status")
    if payment_status != "paid":
        logger.warning(
            "checkout.session.completed with payment_status=%r for order %s",
            payment_status,
            order.id,
        )
        return

    # ── Verify the amount matches ────────────────────────────────────
    # Defense in depth: do not trust the webhook blindly. A mismatch
    # here is a serious reconciliation problem that must be visible in
    # logs, not silently swallowed.
    if session.get("amount_total") != order.total_cents:
        logger.error(
            "Payment amount mismatch on order %s: "
            "Stripe collected %s %s, expected %s %s. "
            "Order left in %s state for manual reconciliation.",
            order.id,
            session.get("amount_total"),
            session.get("currency"),
            order.total_cents,
            order.currency,
            order.status.value,
        )
        return

    if session.get("currency", "").upper() != order.currency.upper():
        logger.error(
            "Payment currency mismatch on order %s: "
            "Stripe=%s expected=%s",
            order.id,
            session.get("currency"),
            order.currency,
        )
        return

    # ── Apply the transition ─────────────────────────────────────────
    if order.status == OrderStatus.pending:
        order.status = OrderStatus.paid
        order.paid_at = dt.datetime.now(dt.timezone.utc)
        # `updated_at` fires automatically via the model's `onupdate`.
        await db.commit()

        logger.info(
            "Order %s marked paid (session=%s amount=%s %s)",
            order.id,
            session.get("id"),
            order.total_cents,
            order.currency,
        )
    else:
        # Duplicate delivery of an event we already processed. Expected
        # under Stripe's at-least-once semantics.
        logger.info(
            "Duplicate checkout.session.completed for order %s "
            "(status already %s)",
            order.id,
            order.status.value,
        )
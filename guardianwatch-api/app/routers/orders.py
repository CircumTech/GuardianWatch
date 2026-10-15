"""
Order endpoints.

CHECKOUT FLOW

  1. `POST /orders`             — creates an order in `pending` status,
                                  reserves stock. Supports guest checkout
                                  (no account required) but links the
                                  order to the signed-in user when one is
                                  present.
  2. `POST /orders/{id}/checkout` — creates a Stripe Checkout Session for
                                  the order and returns the URL. The
                                  frontend redirects the browser there.
  3. Stripe `checkout.session.completed` webhook → order moves to `paid`.
  4. `GET /orders/{id}`          — customer-facing order status lookup.
                                  Requires the checkout email (guest path)
                                  OR the signed-in owner's account.

Why create and checkout are two calls: an abandoned Stripe session should
not force the customer to re-enter shipping details. The order exists
first; the payment session is a separate step that can be retried.
"""
from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from pydantic import EmailStr
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.dependencies import get_current_user, get_current_user_optional
from app.models.user import User
from app.rate_limit import limiter
from app.schemas.order import (
    CheckoutResponse,
    OrderCreateRequest,
    OrderOut,
    OrderSummaryOut,
)
from app.services import order_service, payment_service

router = APIRouter(prefix="/orders", tags=["orders"])


# ─────────────────────────────────────────────────────────────────────────
# Create
# ─────────────────────────────────────────────────────────────────────────


@router.post(
    "",
    status_code=status.HTTP_201_CREATED,
    response_model=OrderOut,
)
async def create_order(
    body: OrderCreateRequest,
    user: User | None = Depends(get_current_user_optional),
    db: AsyncSession = Depends(get_db),
):
    """
    Creates an order in `pending` status and reserves stock.

    Guest-friendly: no account required, matching a normal e-commerce
    flow. When the caller is signed in, the order is linked to their
    account so it appears in `GET /orders/me`.
    """
    return await order_service.create_order(
        db, body, user_id=user.id if user is not None else None
    )


# ─────────────────────────────────────────────────────────────────────────
# Start payment
# ─────────────────────────────────────────────────────────────────────────


@router.post("/{order_id}/checkout", response_model=CheckoutResponse)
@limiter.limit("10/minute")
async def start_checkout(
    request: Request,  # required by @limiter.limit
    order_id: str,
    email: EmailStr = Query(
        ...,
        description=(
            "The email used at checkout. Required, matching the "
            "verification on GET /orders/{order_id} — without it, "
            "knowing an order id alone would be enough to create a "
            "Stripe session for someone else's order."
        ),
    ),
    user: User | None = Depends(get_current_user_optional),
    db: AsyncSession = Depends(get_db),
):
    """
    Creates a Stripe-hosted Checkout Session for an existing pending
    order and returns its URL.

    Separate from order creation so a failed or abandoned Stripe session
    doesn't force re-entering shipping details, and so an order can be
    retried for payment without creating a duplicate.

    Access control matches `GET /orders/{order_id}`: the caller must
    prove ownership by email (guest path) or by signed-in account.
    """
    order = await order_service.get_order(db, order_id)
    if order is None or not _caller_owns_order(order, user, email):
        # Same 404 as GET — do not distinguish "not found" from "not
        # yours", which would be an existence oracle.
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Order not found"
        )

    if order.status != "pending":
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"This order is {order.status} and cannot be paid again."
            ),
        )

    checkout_url = await payment_service.create_checkout_session(db, order_id)
    return CheckoutResponse(order_id=order_id, checkout_url=checkout_url)


# ─────────────────────────────────────────────────────────────────────────
# Customer list
# ─────────────────────────────────────────────────────────────────────────


@router.get("/me", response_model=list[OrderSummaryOut])
async def list_my_orders(
    user: User = Depends(get_current_user),  # requires auth — no guest path
    db: AsyncSession = Depends(get_db),
):
    """
    Returns the signed-in user's order history, most recent first.

    Only includes orders placed while signed in. Guest orders are not
    linked by email — that would reintroduce the email-trust problem
    the lookup endpoints already have.
    """
    orders = await order_service.list_orders_for_user(db, user.id)
    return orders


# ─────────────────────────────────────────────────────────────────────────
# Single order lookup
# ─────────────────────────────────────────────────────────────────────────


@router.get("/{order_id}", response_model=OrderOut)
@limiter.limit("30/minute")
async def get_order(
    request: Request,  # required by @limiter.limit
    order_id: str,
    email: EmailStr = Query(
        ...,
        description=(
            "The email used at checkout. An order id alone is not "
            "sufficient to view an order."
        ),
    ),
    user: User | None = Depends(get_current_user_optional),
    db: AsyncSession = Depends(get_db),
):
    """
    Order status lookup for the confirmation page.

    Requires proving ownership — either the signed-in account that
    placed the order, or the checkout email. An order id alone is
    guessable-ish (or forwardable) and must not be sufficient to pull
    up someone else's name and shipping address.
    """
    order = await order_service.get_order(db, order_id)
    if order is None or not _caller_owns_order(order, user, email):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Order not found"
        )
    return order


# ─────────────────────────────────────────────────────────────────────────
# Ownership check
# ─────────────────────────────────────────────────────────────────────────


def _caller_owns_order(order, user: User | None, email: str) -> bool:
    """
    True if the caller may access this order.

    Two independent paths:
      - Signed-in account matches the order's `user_id` (covers orders
        placed by authenticated users).
      - The checkout email matches (covers guest orders).

    Both checks must fail for access to be denied.
    """
    if user is not None and order.user_id == user.id:
        return True
    return order.customer_email.lower() == email.strip().lower()
"""
Order creation logic.

Kept out of the router so the stock-check-and-decrement, which has to
happen atomically, has one obvious home. See the module docstring in
routers/orders.py for the payment-integration boundary.

IDEMPOTENCY

  Every order carries a client-supplied `idempotency_key`. A retried
  checkout (network hiccup, double-tap) sends the same key, and this
  service returns the existing order instead of creating a duplicate.

  Two code paths enforce this:
    1. Before creating, look up by key. If found, return the existing
       order (handles sequential retries).
    2. On `IntegrityError` from the unique constraint at commit — which
       means a concurrent request with the same key won the race —
       roll back, re-fetch by key, return the existing order.

  Both are required: (1) alone misses concurrent retries; (2) alone
  would raise on the common sequential case before ever reaching the
  lookup.
"""
from __future__ import annotations

import logging

from fastapi import HTTPException, status
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.order import Order
from app.models.product import Product
from app.schemas.order import OrderCreateRequest

logger = logging.getLogger("guardianwrist.orders")


async def create_order(
    db: AsyncSession,
    body: OrderCreateRequest,
    user_id: str | None = None,
) -> Order:
    """
    Creates an order and reserves stock atomically.

    `user_id` is optional — guest checkout is a supported flow. When the
    router has a signed-in user, it should pass their id so the order is
    linked to their account and appears in `GET /me/orders`.
    """
    # ── 1. Idempotency short-circuit ─────────────────────────────────
    # If the client has already submitted this exact checkout attempt,
    # return the existing order. Covers the common case: network drop,
    # client retry with the same key.
    if body.idempotency_key:
        existing = await _get_by_idempotency_key(db, body.idempotency_key)
        if existing is not None:
            logger.info(
                "Idempotent order replay: key=%s order=%s",
                body.idempotency_key,
                existing.id,
            )
            return existing

    # ── 2. Product lookup ────────────────────────────────────────────
    product = await db.get(Product, body.product_id)
    if product is None or not product.active:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Product not found",
        )

    # ── 3. Atomic stock reservation ──────────────────────────────────
    # A read-then-write (`if product.stock_quantity < qty: raise` followed
    # by `product.stock_quantity -= qty`) has a TOCTOU window: two
    # concurrent requests for the last unit both pass the check and both
    # decrement. The conditional UPDATE below is atomic on both SQLite
    # and Postgres — the DB guarantees exactly one of the racing requests
    # sees rowcount == 1.
    stock_result = await db.execute(
        update(Product)
        .where(
            Product.id == product.id,
            Product.stock_quantity >= body.quantity,
        )
        .values(stock_quantity=Product.stock_quantity - body.quantity)
    )

    if stock_result.rowcount == 0:
        # Either stock was insufficient or the product vanished between
        # our SELECT and this UPDATE. Re-fetch for an accurate message.
        await db.rollback()
        fresh = await db.get(Product, body.product_id)
        if fresh is None or not fresh.active:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Product not found",
            )
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Only {fresh.stock_quantity} left in stock.",
        )

    # ── 4. Build the order ───────────────────────────────────────────
    unit_price = product.price_cents

    order = Order(
        # Assigning the relationship populates both `product` (in
        # memory, so no re-fetch is needed for the response) and
        # `product_id` (SQLAlchemy's FK sync).
        product=product,
        user_id=user_id,
        quantity=body.quantity,
        unit_price_cents=unit_price,
        total_cents=unit_price * body.quantity,
        # Defensive: legacy Product rows may have a lowercase currency
        # from before the migration that uppercased everything. OrderOut
        # requires `^[A-Z]{3}$`, so normalize at write time.
        currency=(product.currency or "USD").upper(),
        customer_name=body.customer_name,
        customer_email=body.customer_email,
        shipping_address=body.shipping_address.model_dump(),
        idempotency_key=body.idempotency_key,
    )
    db.add(order)

    # ── 5. Commit with concurrent-retry handling ──────────────────────
    try:
        await db.commit()
    except IntegrityError as exc:
        await db.rollback()

        # The most likely cause is `uq_orders_idempotency_key`: a
        # concurrent request with the same key inserted between our
        # step-1 lookup and this commit. Roll back (which also releases
        # the stock decrement) and return the winner's order.
        if body.idempotency_key:
            winner = await _get_by_idempotency_key(db, body.idempotency_key)
            if winner is not None:
                logger.info(
                    "Concurrent idempotent order resolved: key=%s order=%s",
                    body.idempotency_key,
                    winner.id,
                )
                return winner

        # Anything else — a CHECK constraint violation, a foreign key
        # mismatch, a schema drift — is a genuine bug. Log enough to
        # diagnose and surface a generic error.
        logger.exception("Order commit failed: %r", exc)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Could not complete the order. Please try again.",
        )

    # `product` is already populated on the instance because we assigned
    # the relationship above. `lazy="selectin"` on the relationship means
    # any later access from a fresh session also eager-loads, so the
    # response serializes without an extra query.
    await db.refresh(order)
    return order


async def get_order(db: AsyncSession, order_id: str) -> Order | None:
    """
    Fetches an order with its product eagerly loaded.

    The explicit `selectinload` is defensive — the relationship also has
    `lazy="selectin"` — but making the eager-load explicit here means
    this function's behavior does not silently change if the model's
    lazy strategy is ever revisited.
    """
    result = await db.execute(
        select(Order)
        .where(Order.id == order_id)
        .options(selectinload(Order.product))
    )
    return result.scalar_one_or_none()


async def _get_by_idempotency_key(
    db: AsyncSession, key: str
) -> Order | None:
    """
    Looks up an existing order by its idempotency key.

    Eager-loads `product` so the caller can serialize the response
    without a second query.
    """
    result = await db.execute(
        select(Order)
        .where(Order.idempotency_key == key)
        .options(selectinload(Order.product))
    )
    return result.scalar_one_or_none()

async def list_orders_for_user(
    db: AsyncSession, user_id: str
) -> list[Order]:
    """
    Returns the user's orders, most recent first.

    Product is eagerly loaded via `lazy="selectin"` on the relationship,
    so no explicit `selectinload` is required here. `OrderSummaryOut`
    does not nest the product anyway.
    """
    result = await db.execute(
        select(Order)
        .where(Order.user_id == user_id)
        .order_by(Order.created_at.desc())
    )
    return list(result.scalars().all())
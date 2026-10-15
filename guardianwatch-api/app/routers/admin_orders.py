import datetime as dt

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.database import get_db
from app.dependencies import get_current_admin
from app.models.admin_user import AdminUser
from app.models.order import Order, OrderStatus
from app.models.product import Product
from app.rate_limit import limiter
from app.schemas.admin import OrderStatusUpdateRequest
from app.schemas.order import OrderOut
from app.services import admin_audit_service

router = APIRouter(prefix="/admin/orders", tags=["admin-orders"])

# Allowed transitions. Every state is terminal except `pending`, which
# can only move to `paid` (payment confirmed) or `cancelled` (abandoned
# or explicitly cancelled by an admin). Fulfilled orders cannot be
# un-fulfilled by this endpoint; a refund would be a separate flow.
_ALLOWED_TRANSITIONS: dict[OrderStatus, set[OrderStatus]] = {
    OrderStatus.pending: {OrderStatus.paid, OrderStatus.cancelled},
    OrderStatus.paid: {OrderStatus.fulfilled, OrderStatus.cancelled},
    OrderStatus.fulfilled: set(),  # terminal
    OrderStatus.cancelled: set(),  # terminal
}


@router.get("", response_model=list[OrderOut])
@limiter.limit("60/minute")
async def list_orders(
    request: Request,  # required by @limiter.limit
    status_filter: OrderStatus | None = Query(default=None, alias="status"),
    page: int = Query(default=0, ge=0),
    limit: int = Query(default=50, ge=1, le=200),
    admin: AdminUser = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    query = (
        select(Order)
        .options(selectinload(Order.product))
        .order_by(Order.created_at.desc(), Order.id.asc())
        .offset(page * limit)
        .limit(limit)
    )
    if status_filter is not None:
        query = query.where(Order.status == status_filter)

    result = await db.execute(query)
    return result.scalars().all()


@router.patch("/{order_id}/status", response_model=OrderOut)
async def update_order_status(
    order_id: str,
    body: OrderStatusUpdateRequest,
    admin: AdminUser = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    """
    Manual status override for fulfillment ("mark shipped"), handling
    disputed orders, or cancelling an unpaid order. Normal payment
    confirmation happens automatically via the Stripe webhook — this
    endpoint is not on the payment path.

    Status transitions are validated against `_ALLOWED_TRANSITIONS`.
    Cancelling an order restores the stock reserved at creation time,
    so inventory is not lost when a customer abandons checkout or an
    admin cancels a fraudulent order.
    """
    result = await db.execute(
        select(Order)
        .where(Order.id == order_id)
        .options(selectinload(Order.product))
    )
    order = result.scalar_one_or_none()
    if order is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Order not found"
        )

    try:
        new_status = OrderStatus(body.status)
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid status: {body.status}",
        )

    old_status = order.status
    if new_status == old_status:
        # No-op — return the current state without touching the timeline.
        return order

    allowed = _ALLOWED_TRANSITIONS.get(old_status, set())
    if new_status not in allowed:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"Cannot transition from {old_status.value} to "
                f"{new_status.value}. Allowed: "
                f"{sorted(s.value for s in allowed) or 'none'}."
            ),
        )

    now = dt.datetime.now(dt.timezone.utc)

    # ── Restore stock on cancellation ────────────────────────────────
    # Only restore if the order was still holding reserved inventory.
    # `fulfilled` orders already consumed the stock; `cancelled` is
    # terminal; only `pending` and `paid` cancellations need the
    # restore.
    if new_status == OrderStatus.cancelled and old_status in (
        OrderStatus.pending,
        OrderStatus.paid,
    ):
        await db.execute(
            update(Product)
            .where(Product.id == order.product_id)
            .values(stock_quantity=Product.stock_quantity + order.quantity)
        )

    # ── Apply transition and set the matching timestamp ──────────────
    order.status = new_status
    if new_status == OrderStatus.paid:
        order.paid_at = order.paid_at or now
    elif new_status == OrderStatus.fulfilled:
        order.fulfilled_at = now
    elif new_status == OrderStatus.cancelled:
        order.cancelled_at = now

    await admin_audit_service.record(
        db,
        admin,
        action="order.status_update",
        resource_type="order",
        resource_id=order.id,
        detail={
            "from": old_status.value,
            "to": new_status.value,
            "stock_restored": new_status == OrderStatus.cancelled
            and old_status in (OrderStatus.pending, OrderStatus.paid),
        },
        commit=False,
    )

    await db.commit()
    await db.refresh(order)
    return order
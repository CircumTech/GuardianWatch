"""
Aggregate-only views: counts and sums, never a single row of health data.
This is the entire admin "reporting" surface — deliberately thin.
"""
import asyncio

from fastapi import APIRouter, Depends, Query
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.dependencies import get_current_admin
from app.models.admin_audit_log import AdminAuditLog
from app.models.admin_user import AdminUser
from app.models.device import Device, DeviceStatus
from app.models.order import Order, OrderStatus
from app.models.product import Product
from app.models.user import User
from app.schemas.admin import AuditLogEntryOut, DashboardStats

router = APIRouter(prefix="/admin", tags=["admin-dashboard"])


@router.get("/dashboard/stats", response_model=DashboardStats)
async def get_dashboard_stats(
    admin: AdminUser = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    """
    Aggregate counters for the admin dashboard.

    All queries execute concurrently via `asyncio.gather`. Sequential
    awaits against a remote Postgres add 20ms per query for data that
    could be fetched in parallel; the four metric groups below fire at
    the same time, so wall time is the slowest query, not the sum.
    """

    async def count(query):
        result = await db.execute(query)
        return result.scalar_one()

    # Group queries by concern so the gather call is readable.
    (
        total_customers,
        total_products,
        total_devices,
        devices_registered,
        devices_unregistered,
        total_orders,
        orders_pending,
        orders_paid,
        orders_fulfilled,
        revenue,
    ) = await asyncio.gather(
        count(select(func.count()).select_from(User)),
        count(select(func.count()).select_from(Product)),
        count(select(func.count()).select_from(Device)),
        count(
            select(func.count())
            .select_from(Device)
            .where(Device.status == DeviceStatus.registered)
        ),
        count(
            select(func.count())
            .select_from(Device)
            .where(Device.status == DeviceStatus.unregistered)
        ),
        count(select(func.count()).select_from(Order)),
        count(
            select(func.count())
            .select_from(Order)
            .where(Order.status == OrderStatus.pending)
        ),
        count(
            select(func.count())
            .select_from(Order)
            .where(Order.status == OrderStatus.paid)
        ),
        count(
            select(func.count())
            .select_from(Order)
            .where(Order.status == OrderStatus.fulfilled)
        ),
        count(
            select(func.coalesce(func.sum(Order.total_cents), 0))
            .select_from(Order)
            .where(Order.status.in_([OrderStatus.paid, OrderStatus.fulfilled]))
        ),
    )

    return DashboardStats(
        total_customers=total_customers,
        total_products=total_products,
        total_devices=total_devices,
        devices_registered=devices_registered,
        devices_unregistered=devices_unregistered,
        total_orders=total_orders,
        orders_pending=orders_pending,
        orders_paid=orders_paid,
        orders_fulfilled=orders_fulfilled,
        # Postgres `SUM` returns Decimal; Pydantic's `int` field accepts
        # it but the explicit conversion makes the type boundary clear.
        revenue_paid_cents=int(revenue),
    )


@router.get("/audit-log", response_model=list[AuditLogEntryOut])
async def get_audit_log(
    page: int = Query(default=0, ge=0),
    limit: int = Query(default=100, ge=1, le=500),
    admin: AdminUser = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    """
    Paginated admin audit log, most recent first.

    Pagination added because long-lived deployments accumulate audit
    entries quickly — without an offset the admin can only ever see the
    most recent N.
    """
    result = await db.execute(
        select(AdminAuditLog)
        .order_by(AdminAuditLog.created_at.desc())
        .offset(page * limit)
        .limit(limit)
    )
    return result.scalars().all()
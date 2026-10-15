"""
Import every model module here so `Base.metadata` sees all tables before
`init_db()` / Alembic autogenerate runs. SQLAlchemy relationships resolve
their string references (e.g. `Mapped["User"]`) against this registry.
"""
from app.models.user import User
from app.models.reading import Reading
from app.models.insight import Insight, InsightSeverity
from app.models.subscription import Subscription, IAPPlatform, SubscriptionStatus
from app.models.product import Product
from app.models.device import Device, DeviceStatus
from app.models.order import Order, OrderStatus
from app.models.admin_user import AdminUser
from app.models.admin_audit_log import AdminAuditLog

__all__ = [
    "User",
    "Reading",
    "Insight",
    "InsightSeverity",
    "Subscription",
    "IAPPlatform",
    "SubscriptionStatus",
    "Product",
    "Device",
    "DeviceStatus",
    "Order",
    "OrderStatus",
    "AdminUser",
    "AdminAuditLog",
]

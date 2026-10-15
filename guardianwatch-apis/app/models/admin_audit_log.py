"""
AdminAuditLog — an append-only record of what admin actions changed what,
and who did it.

There is deliberately no update or delete route for this table (see
routers/admin_* — the only write path is `admin_audit_service.record`).
The point of an audit log is that it is the one thing even an admin
cannot quietly rewrite.

`admin_email` is denormalized at write time so the entry remains
readable even after the admin account is removed. There is no foreign
key on `admin_id` for the same reason: an FK with CASCADE would delete
the audit entries, and an FK with RESTRICT would prevent deleting the
admin.
"""
import datetime as dt
import uuid

from sqlalchemy import JSON, Index, String
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base
from app.utils.db_types import UTCDateTime


class AdminAuditLog(Base):
    __tablename__ = "admin_audit_log"
    __table_args__ = (
        # Common admin queries: "what happened to this device/order/
        # product" and "what did this admin do". Both filter first on
        # one of these pairs. Without the indexes those queries are
        # table scans as the log grows.
        Index("ix_admin_audit_resource", "resource_type", "resource_id"),
        Index("ix_admin_audit_admin_created", "admin_id", "created_at"),
    )

    id: Mapped[str] = mapped_column(
        String(36),
        primary_key=True,
        default=lambda: uuid.uuid4().hex,
    )

    # No FK — see module docstring. The denormalized admin_email below
    # is what keeps entries readable after the admin is removed.
    admin_id: Mapped[str] = mapped_column(
        String(36), nullable=False, index=True
    )
    admin_email: Mapped[str] = mapped_column(String(320), nullable=False)

    # Examples: "product.create", "product.update", "device.deactivate",
    # "order.status_update".
    action: Mapped[str] = mapped_column(String(64), nullable=False)

    # Examples: "product", "device", "order".
    resource_type: Mapped[str] = mapped_column(String(64), nullable=False)

    # Widest resource id in the system is `Product.id` at 64 chars.
    resource_id: Mapped[str] = mapped_column(String(64), nullable=False)

    # Free-form diff / context. `nullable=False` with a Python-side
    # `default=dict` guarantees that a row is never written without one.
    # Without `nullable=False`, a direct SQL INSERT that omits this
    # column would leave it NULL, and the Pydantic `dict` field on
    # `AuditLogEntryOut` would raise on read.
    detail: Mapped[dict] = mapped_column(
        JSON, default=dict, nullable=False
    )

    created_at: Mapped[dt.datetime] = mapped_column(
        UTCDateTime(),
        default=lambda: dt.datetime.now(dt.timezone.utc),
        nullable=False,
        index=True,
    )
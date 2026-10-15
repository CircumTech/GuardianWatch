"""
Subscription model — tracks IAP receipts verified via POST /subscription/verify.

One row per verification attempt (append-only audit trail) rather than a
single mutable row per user. `User.premium` is the fast-path flag actually
read by the app; this table is the record of *why* it's set, which matters
the moment a chargeback, refund, or expiry needs investigating.
"""
import datetime as dt
import enum

from sqlalchemy import Enum, ForeignKey, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base
from app.utils.db_types import UTCDateTime


class IAPPlatform(str, enum.Enum):
    ios = "ios"
    android = "android"


class SubscriptionStatus(str, enum.Enum):
    active = "active"
    expired = "expired"
    invalid = "invalid"
    cancelled = "cancelled"


class Subscription(Base):
    __tablename__ = "subscriptions"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    user_id: Mapped[str] = mapped_column(
        String(128),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )

    product_id: Mapped[str] = mapped_column(String(255), nullable=False)

    # Nullable: a legacy client or a malformed probe may arrive without a
    # recognized platform string. Recording `NULL` is honest — defaulting
    # to iOS (as an earlier revision did) corrupts the audit trail for
    # Android users on legacy builds.
    platform: Mapped[IAPPlatform | None] = mapped_column(
        Enum(IAPPlatform, native_enum=False, length=16),
        nullable=True,
    )

    status: Mapped[SubscriptionStatus] = mapped_column(
        Enum(SubscriptionStatus, native_enum=False, length=16)
    )

    # The store's transaction identifier (Apple: transaction_id; Google:
    # orderId). Needed to correlate this row with a later refund or
    # App Store Server Notification, which carry the transaction id but
    # not the original receipt.
    transaction_id: Mapped[str | None] = mapped_column(String(255), nullable=True)

    raw_receipt: Mapped[str | None] = mapped_column(Text, nullable=True)

    verified_at: Mapped[dt.datetime] = mapped_column(
        UTCDateTime(),
        default=lambda: dt.datetime.now(dt.timezone.utc),
        index=True,
    )
    expires_at: Mapped[dt.datetime | None] = mapped_column(
        UTCDateTime(), nullable=True
    )

    user: Mapped["User"] = relationship(back_populates="subscriptions")  # noqa: F821
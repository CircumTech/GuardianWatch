"""
Order — a purchase of a Product.

`status` starts at `pending` and advances through `paid → fulfilled`, or
`cancelled`. See routers/orders.py for where the payment processor is
consulted before transitioning to `paid`.

IDEMPOTENCY

  Every order carries a client-supplied `idempotency_key`. A retried
  checkout (network hiccup, double-tap) sends the same key, and the
  server returns the existing order instead of creating a new one. The
  key is unique across the table — a duplicate insert is rejected at
  the DB level, and the router catches that to return the original
  order.

  The client generates the key once per checkout attempt (a UUID works)
  and reuses it across all retries of that attempt.
"""
import datetime as dt
import enum
import uuid

from sqlalchemy import (
    CheckConstraint,
    Enum,
    ForeignKey,
    Index,
    Integer,
    JSON,
    String,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base
from app.utils.db_types import UTCDateTime


class OrderStatus(str, enum.Enum):
    pending = "pending"      # created, awaiting payment confirmation
    paid = "paid"
    fulfilled = "fulfilled"  # shipped
    cancelled = "cancelled"


class Order(Base):
    __tablename__ = "orders"
    __table_args__ = (
        # Idempotency: a client can safely retry a checkout without
        # creating a duplicate order. A duplicate insert raises
        # IntegrityError, which the router catches and converts into a
        # "return the existing order" response.
        UniqueConstraint(
            "idempotency_key",
            name="uq_orders_idempotency_key",
        ),
        # Invariants that must hold regardless of how the row is
        # inserted — API, seed script, admin SQL, future migration.
        CheckConstraint(
            "quantity >= 1",
            name="ck_orders_quantity_positive",
        ),
        CheckConstraint(
            "unit_price_cents >= 0",
            name="ck_orders_unit_price_non_negative",
        ),
        CheckConstraint(
            "total_cents >= 0",
            name="ck_orders_total_non_negative",
        ),
        CheckConstraint(
            "total_cents = unit_price_cents * quantity",
            name="ck_orders_total_matches_quantity",
        ),
        CheckConstraint(
            "length(currency) = 3",
            name="ck_orders_currency_length",
        ),
        # Admin queries: "paid orders today", "pending > 24h".
        Index("ix_orders_status_created", "status", "created_at"),
        # Customer queries: "my orders".
        Index("ix_orders_user_id", "user_id"),
    )

    id: Mapped[str] = mapped_column(
        String(36),
        primary_key=True,
        # UUIDv4 with dashes. Model length is exactly 36 — do not change
        # the generator without widening the column.
        default=lambda: str(uuid.uuid4()),
    )

    # Client-supplied idempotency key. See class docstring.
    idempotency_key: Mapped[str | None] = mapped_column(
        String(64), nullable=True
    )

    product_id: Mapped[str] = mapped_column(
        String(64),
        ForeignKey("products.id", ondelete="RESTRICT"),
        nullable=False,
    )

    # Nullable — checkout does not require a GuardianWrist account today,
    # matching how the site's shop is public/guest-friendly.
    user_id: Mapped[str | None] = mapped_column(
        String(128),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )

    quantity: Mapped[int] = mapped_column(Integer, nullable=False)

    # Prices are snapshots at order time. If the Product's price later
    # changes, the order must remain at the price the customer agreed
    # to — hence these are stored on the order itself, not joined from
    # the product.
    unit_price_cents: Mapped[int] = mapped_column(Integer, nullable=False)
    total_cents: Mapped[int] = mapped_column(Integer, nullable=False)

    # ISO 4217 uppercase. Matches Product.currency format so the two
    # can be compared without normalization.
    currency: Mapped[str] = mapped_column(
        String(3), default="USD", nullable=False
    )

    customer_name: Mapped[str] = mapped_column(String(255), nullable=False)
    customer_email: Mapped[str] = mapped_column(
        String(320), nullable=False, index=True
    )
    shipping_address: Mapped[dict] = mapped_column(
        JSON, default=dict, nullable=False
    )

    status: Mapped[OrderStatus] = mapped_column(
        Enum(OrderStatus, native_enum=False, length=16),
        default=OrderStatus.pending,
        nullable=False,
    )

    # ── Timestamps ───────────────────────────────────────────────────
    #
    # The status enum tells you the current state, not when it changed.
    # These three columns capture the transitions needed for customer
    # support ("my order shows fulfilled but never arrived") and admin
    # analytics (average order-to-ship time).
    created_at: Mapped[dt.datetime] = mapped_column(
        UTCDateTime(),
        default=lambda: dt.datetime.now(dt.timezone.utc),
        nullable=False,
    )
    paid_at: Mapped[dt.datetime | None] = mapped_column(
        UTCDateTime(), nullable=True
    )
    fulfilled_at: Mapped[dt.datetime | None] = mapped_column(
        UTCDateTime(), nullable=True
    )
    cancelled_at: Mapped[dt.datetime | None] = mapped_column(
        UTCDateTime(), nullable=True
    )
    updated_at: Mapped[dt.datetime] = mapped_column(
        UTCDateTime(),
        default=lambda: dt.datetime.now(dt.timezone.utc),
        onupdate=lambda: dt.datetime.now(dt.timezone.utc),
        nullable=False,
    )

    # `lazy="selectin"` because `OrderOut` always serializes the product.
    # Without it, Pydantic's sync `model_validate(order)` triggers a
    # lazy load, and lazy loading is not allowed in async SQLAlchemy —
    # it raises MissingGreenlet. This eager load happens automatically
    # on every Order read.
    product: Mapped["Product"] = relationship(  # noqa: F821
        back_populates="orders", lazy="selectin"
    )
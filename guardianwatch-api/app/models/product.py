"""
Product — a purchasable SKU (e.g. "GuardianWatch Classic").

Public catalog data only; nothing here is user-specific. `id` doubles as
a URL-friendly slug ("guardianwatch-classic") since products are looked
up by it directly in the shop's product-detail route.

DELETION POLICY

  Products are never hard-deleted once they have devices or orders
  attached — the FK on `devices.product_id` has `ondelete="RESTRICT"`
  which enforces this at the DB level. Retire a SKU by setting
  `active = False`; the storefront filters on that flag.
"""
import datetime as dt

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    Integer,
    JSON,
    String,
    Text,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base
from app.utils.db_types import UTCDateTime


class Product(Base):
    __tablename__ = "products"
    __table_args__ = (
        # These are belt-and-braces on top of the Pydantic validators in
        # `schemas/product.py`. The API surface is protected by Pydantic;
        # the DB surface is protected by these. Scripts, admin tools, and
        # future code paths that bypass the API are the target.
        #
        # Only portable checks are declared here (SQLite GLOB and Postgres
        # regex have different syntax for the same pattern). Stricter
        # validation (ISO 4217 format, slug pattern) lives in the schema.
        CheckConstraint(
            "price_cents >= 0",
            name="ck_products_price_non_negative",
        ),
        CheckConstraint(
            "stock_quantity >= 0",
            name="ck_products_stock_non_negative",
        ),
        CheckConstraint(
            "length(currency) = 3",
            name="ck_products_currency_length",
        ),
    )

    # URL-friendly slug. Kept short; a slug like `guardianwatch-classic`
    # fits comfortably. The schema-level validator enforces the character
    # class — this column only bounds the length.
    id: Mapped[str] = mapped_column(String(64), primary_key=True)

    name: Mapped[str] = mapped_column(String(255), nullable=False)
    tagline: Mapped[str | None] = mapped_column(String(255), nullable=True)
    description: Mapped[str] = mapped_column(Text, nullable=False)

    # Integer cents. Float prices accumulate rounding error across cart
    # math and order totals — always store money as the smallest unit.
    price_cents: Mapped[int] = mapped_column(Integer, nullable=False)

    # ISO 4217 uppercase. Model default is uppercase so a
    # default-constructed row is valid against the schema without a
    # normalization step. Uppercasing on write is also enforced in the
    # schema validator.
    currency: Mapped[str] = mapped_column(
        String(3), default="USD", nullable=False
    )

    # Widened from 1024 to 2048 for consistency with `User.photo_url`.
    # Signed CDN URLs with query parameters regularly exceed 1024.
    image_url: Mapped[str | None] = mapped_column(String(2048), nullable=True)

    # Free-form spec sheet, e.g. {"battery_life": "5 days", "sensors": [...]}
    # — rendered directly on the product page, no schema migration needed
    # to add/change a spec line.
    specs: Mapped[dict] = mapped_column(JSON, default=dict, nullable=False)

    stock_quantity: Mapped[int] = mapped_column(
        Integer, default=0, nullable=False
    )

    # Soft-delete flag. Storefront queries filter on `active = True`;
    # admin queries do not. See routers/products.py for the read split.
    active: Mapped[bool] = mapped_column(
        Boolean, default=True, nullable=False
    )

    created_at: Mapped[dt.datetime] = mapped_column(
        UTCDateTime(),
        default=lambda: dt.datetime.now(dt.timezone.utc),
        nullable=False,
    )
    updated_at: Mapped[dt.datetime] = mapped_column(
        UTCDateTime(),
        default=lambda: dt.datetime.now(dt.timezone.utc),
        onupdate=lambda: dt.datetime.now(dt.timezone.utc),
        nullable=False,
    )

    # No cascade — a Product with devices or orders is never hard-deleted.
    # The FK on `devices.product_id` is RESTRICT, which enforces this at
    # the DB level even if this rule is violated in code.
    devices: Mapped[list["Device"]] = relationship(back_populates="product")  # noqa: F821
    orders: Mapped[list["Order"]] = relationship(back_populates="product")  # noqa: F821
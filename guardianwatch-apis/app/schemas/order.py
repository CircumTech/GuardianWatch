import datetime as dt
from typing import Literal

from pydantic import BaseModel, ConfigDict, EmailStr, Field

from app.schemas.product import ProductOut

OrderStatusLiteral = Literal["pending", "paid", "fulfilled", "cancelled"]

# Product IDs are URL-friendly slugs (`guardianwatch-classic`).
# Enforced here so a client cannot inject arbitrary strings that would
# only fail later at the DB.
_PRODUCT_ID_PATTERN = r"^[a-z0-9-]{2,64}$"


class ShippingAddress(BaseModel):
    """
    Structured shipping address.

    Field limits are deliberately tight. A form should never need more
    than these, and unbounded strings on a public checkout endpoint are
    a DoS vector.
    """
    street: str = Field(..., min_length=1, max_length=255)
    city: str = Field(..., min_length=1, max_length=120)
    state: str | None = Field(default=None, max_length=120)
    postal_code: str = Field(..., min_length=1, max_length=20)
    # ISO 3166-1 alpha-2 (NG, US, GB). Constrains the format so the
    # downstream shipping integration cannot receive "Nigeria " with a
    # trailing space, or "NGA", or an arbitrary free-text country name.
    country: str = Field(
        ...,
        min_length=2,
        max_length=2,
        pattern=r"^[A-Z]{2}$",
    )


class OrderCreateRequest(BaseModel):
    product_id: str = Field(
        ...,
        pattern=_PRODUCT_ID_PATTERN,
        description="Product slug.",
    )
    quantity: int = Field(default=1, ge=1, le=10)
    customer_name: str = Field(..., min_length=1, max_length=255)
    customer_email: EmailStr
    shipping_address: ShippingAddress
    # Client-supplied idempotency key. Sent by the checkout screen so a
    # retried request (network hiccup, double-tap) returns the existing
    # order instead of creating a duplicate. Should be a UUID or similar
    # opaque identifier; the server does not interpret it.
    idempotency_key: str | None = Field(default=None, max_length=64)


class CheckoutResponse(BaseModel):
    """
    Returned by POST /orders. The frontend redirects the browser to
    `checkout_url` to complete payment (Stripe Checkout).
    """
    order_id: str
    checkout_url: str


class OrderOut(BaseModel):
    """
    Customer-facing order representation.

    Includes `shipping_address` so the buyer can review what they
    submitted on their order confirmation page — omitting it (as an
    earlier revision did) forced a redundant second call.

    Excludes `idempotency_key` — that is server-side bookkeeping and
    has no meaning to the client.
    """
    model_config = ConfigDict(from_attributes=True)

    id: str
    product: ProductOut
    quantity: int
    unit_price_cents: int
    total_cents: int
    currency: str = Field(..., pattern=r"^[A-Z]{3}$")
    customer_name: str
    customer_email: str
    shipping_address: ShippingAddress
    user_id: str | None = None
    status: OrderStatusLiteral
    created_at: dt.datetime
    paid_at: dt.datetime | None = None
    fulfilled_at: dt.datetime | None = None
    cancelled_at: dt.datetime | None = None


class OrderSummaryOut(BaseModel):
    """
    Lightweight order row for list views (admin order tables, customer
    order history). Omits the full `ProductOut` and the shipping
    address, which are only needed on the detail page.
    """
    model_config = ConfigDict(from_attributes=True)

    id: str
    product_id: str
    quantity: int
    total_cents: int
    currency: str = Field(..., pattern=r"^[A-Z]{3}$")
    customer_email: str
    status: OrderStatusLiteral
    created_at: dt.datetime
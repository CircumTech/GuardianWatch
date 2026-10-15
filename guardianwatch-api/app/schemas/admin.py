import datetime as dt
from typing import Literal

from pydantic import BaseModel, ConfigDict, EmailStr, Field

from app.schemas.product import PRODUCT_ID_PATTERN

# Order status — matches the OrderStatus enum in app/models/order.py.
# Constrained at the schema level so FastAPI returns a 422 with a clear
# message on invalid input rather than leaving the router to raise a 400.
OrderStatusLiteral = Literal["pending", "paid", "fulfilled", "cancelled"]

# Device status — matches the DeviceStatus enum in app/models/device.py.
DeviceStatusLiteral = Literal["unregistered", "registered", "deactivated"]

# Role values currently in use. Kept as a Literal rather than a bare
# `str` so an admin cannot be assigned an arbitrary role by accident.
# Adding a role (e.g. "support") means adding it here and updating the
# checks in routers/admin_*.
AdminRoleLiteral = Literal["admin"]


# ── Auth ─────────────────────────────────────────────────────────────────


class AdminLoginRequest(BaseModel):
    email: EmailStr
    # Unbounded strings on a credential-check endpoint are a DoS vector:
    # the bcrypt comparison on a 10 MB password takes real CPU.
    password: str = Field(..., min_length=8, max_length=128)


class AdminOut(BaseModel):
    """
    Admin identity as returned by the API.

    Includes `is_active` and `last_login_at` so the admin settings page
    can show status without a second request.
    """
    model_config = ConfigDict(from_attributes=True)

    id: str
    email: str
    display_name: str
    role: AdminRoleLiteral
    is_active: bool
    created_at: dt.datetime
    last_login_at: dt.datetime | None = None


class AdminTokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int
    admin: AdminOut


# ── Product management ───────────────────────────────────────────────────


class ProductCreateRequest(BaseModel):
    """
    Body for POST /admin/products.

    `id` is a URL-facing slug. Chosen explicitly by the admin (rather
    than auto-generated) because it appears in the public product URL.
    Once set it is immutable — `ProductUpdateRequest` does not expose it.
    """
    id: str = Field(
        ...,
        pattern=PRODUCT_ID_PATTERN,
        description="URL-friendly slug.",
    )
    name: str = Field(..., min_length=1, max_length=255)
    tagline: str | None = Field(default=None, max_length=255)
    description: str = Field(..., min_length=1)

    # Integer cents. Matches Product.price_cents semantics.
    price_cents: int = Field(..., ge=0)

    # ISO 4217 uppercase. Model default is also "USD" — this stays in sync.
    currency: str = Field(default="USD", pattern=r"^[A-Z]{3}$")

    image_url: str | None = Field(default=None, max_length=2048)

    specs: dict = Field(default_factory=dict)

    stock_quantity: int = Field(default=0, ge=0)


class ProductUpdateRequest(BaseModel):
    """
    Body for PATCH /admin/products/{id}.

    All fields optional; only provided fields change. `id` is
    intentionally not present — the slug is immutable once created,
    since changing it would break every existing link and reference.
    """
    name: str | None = Field(default=None, min_length=1, max_length=255)
    tagline: str | None = Field(default=None, max_length=255)
    description: str | None = Field(default=None, min_length=1)
    price_cents: int | None = Field(default=None, ge=0)
    currency: str | None = Field(default=None, pattern=r"^[A-Z]{3}$")
    image_url: str | None = Field(default=None, max_length=2048)
    specs: dict | None = None
    stock_quantity: int | None = Field(default=None, ge=0)
    active: bool | None = None


# ── Device management ────────────────────────────────────────────────────


class DeviceProvisionRequest(BaseModel):
    """
    Body for POST /admin/devices/provision.

    Bounds enforced here rather than in the router so FastAPI's automatic
    validation and OpenAPI docs reflect the constraint.
    """
    product_id: str = Field(
        ...,
        pattern=PRODUCT_ID_PATTERN,
        description="Product slug.",
    )
    quantity: int = Field(
        default=1,
        ge=1,
        le=500,
        description="Number of units to provision. Batch ceiling of 500.",
    )
    warranty_months: int = Field(default=12, ge=1, le=120)


class AdminDeviceOut(BaseModel):
    """
    Admin/support view of a physical device.

    Includes owner contact info — a support agent looking at a specific
    unit needs to know who to contact. What it never includes: anything
    about that owner's health readings or insights. There is no such
    field here, and no endpoint returns one — the boundary is enforced
    by the shape of this schema, not by a permission check.
    """
    model_config = ConfigDict(from_attributes=True)

    id: str
    product: "ProductOut"  # noqa: F821  (imported below to avoid a cycle)
    status: DeviceStatusLiteral
    owner_user_id: str | None = None
    owner_email: str | None = None
    firmware_version: str | None = None
    warranty_months: int
    manufactured_at: dt.datetime
    registered_at: dt.datetime | None = None


# ── Order management ─────────────────────────────────────────────────────


class OrderStatusUpdateRequest(BaseModel):
    """
    Body for PATCH /admin/orders/{id}/status.

    Constrained to the four valid statuses. FastAPI rejects anything
    else with a 422 and a clear message before the router runs.
    """
    status: OrderStatusLiteral


# ── Dashboard ────────────────────────────────────────────────────────────


class DashboardStats(BaseModel):
    total_customers: int
    total_products: int
    total_devices: int
    devices_registered: int
    devices_unregistered: int
    total_orders: int
    orders_pending: int
    orders_paid: int
    orders_fulfilled: int
    revenue_paid_cents: int
    # Uppercase default for consistency with Product and Order currency
    # fields. The dashboard displays a single currency symbol derived
    # from this value.
    currency: str = Field(default="USD", pattern=r"^[A-Z]{3}$")


# ── Audit log ────────────────────────────────────────────────────────────


class AuditLogEntryOut(BaseModel):
    """
    A single admin audit log entry.

    Read-only view — no write endpoint exists for this table (see the
    model docstring). `admin_email` is denormalized at write time so the
    entry remains readable even if the admin account is later removed.
    """
    model_config = ConfigDict(from_attributes=True)

    id: str
    admin_email: str
    action: str
    resource_type: str
    resource_id: str
    detail: dict = Field(default_factory=dict)
    created_at: dt.datetime


# Resolve the forward reference used inside AdminDeviceOut. Imported here
# rather than at the top of the module to avoid a circular import between
# admin.py and product.py (product.py does not depend on admin.py, but
# admin.py imports from order.py, which imports from product.py, which
# could be extended to import from admin.py in the future).
from app.schemas.product import ProductOut  # noqa: E402

AdminDeviceOut.model_rebuild()
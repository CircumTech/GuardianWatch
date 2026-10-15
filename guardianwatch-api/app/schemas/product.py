import datetime as dt

from pydantic import BaseModel, ConfigDict, Field, computed_field

# Product IDs are URL-friendly slugs (`guardianwatch-classic`). Exported
# so routes and request schemas can reference the same pattern without
# redefining it.
PRODUCT_ID_PATTERN = r"^[a-z0-9-]{2,64}$"


class ProductSummaryOut(BaseModel):
    """
    Lightweight product representation for grid views.

    Omits `description` and `specs` — the two large fields a storefront
    grid does not render. Same design as `OrderSummaryOut`: full detail
    on the detail page, minimal payload in lists.
    """
    model_config = ConfigDict(from_attributes=True)

    id: str
    name: str = Field(..., min_length=1, max_length=255)
    tagline: str | None = Field(default=None, max_length=255)
    price_cents: int = Field(..., ge=0)
    currency: str = Field(..., pattern=r"^[A-Z]{3}$")
    image_url: str | None = Field(default=None, max_length=2048)
    stock_quantity: int = Field(..., ge=0)

    @computed_field  # type: ignore[prop-decorator]
    @property
    def in_stock(self) -> bool:
        return self.stock_quantity > 0


class ProductOut(ProductSummaryOut):
    """
    Full product representation for the detail page and nested device
    responses.

    Inherits every field from `ProductSummaryOut` and adds the two
    heavy fields. The inheritance relationship means a change to the
    shared fields cannot drift between the two views.
    """
    description: str = Field(..., min_length=1)
    specs: dict = Field(default_factory=dict)


class AdminProductOut(ProductOut):
    """
    Admin view — adds soft-delete state and audit timestamps.

    Not returned by any public endpoint. Consumed by the admin panel's
    product management page.
    """
    active: bool
    created_at: dt.datetime
    updated_at: dt.datetime
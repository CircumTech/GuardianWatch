"""
Public product catalog.

Two read endpoints, both unauthenticated:
  - `GET /products`         — grid listing, paginated, minimal payload.
  - `GET /products/{slug}`  — full detail for the product page.

Storefront-facing only. The admin panel uses `routers/admin_products.py`,
which returns the `AdminProductOut` view including soft-delete state and
audit timestamps.
"""
from fastapi import APIRouter, Depends, HTTPException, Path, Query, Request, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.models.product import Product
from app.rate_limit import limiter
from app.schemas.product import (
    PRODUCT_ID_PATTERN,
    ProductOut,
    ProductSummaryOut,
)

router = APIRouter(prefix="/products", tags=["products"])


@router.get("", response_model=list[ProductSummaryOut])
@limiter.limit("60/minute")
async def list_products(
    request: Request,  # required by @limiter.limit
    page: int = Query(default=0, ge=0),
    limit: int = Query(default=24, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
):
    """
    Public catalog — the shop page's product grid.

    Paginated. `24` per page matches a typical grid layout (4 columns
    × 6 rows on desktop, 2 columns × 12 rows on mobile). Returns
    summaries, not full products — the grid does not render
    `description` or `specs`.

    Inactive products are excluded. There is no query parameter to see
    them; that view lives on the admin endpoint.
    """
    result = await db.execute(
        select(Product)
        .where(Product.active.is_(True))
        # Explicit ORDER BY — Postgres does not guarantee row order
        # without one, so a missing sort means products shuffle between
        # page loads. Newest first is the conventional storefront
        # default.
        .order_by(Product.created_at.desc(), Product.id.asc())
        .offset(page * limit)
        .limit(limit)
    )
    return result.scalars().all()


@router.get("/{product_id}", response_model=ProductOut)
@limiter.limit("60/minute")
async def get_product(
    request: Request,  # required by @limiter.limit
    product_id: str = Path(
        ...,
        pattern=PRODUCT_ID_PATTERN,
        description="Product slug.",
    ),
    db: AsyncSession = Depends(get_db),
):
    """
    Public product detail page.

    Returns 404 for a product that does not exist OR is inactive —
    the storefront should not be able to distinguish "this slug was
    never used" from "this product was deactivated." Only admins can
    see hidden products.
    """
    product = await db.get(Product, product_id)
    if product is None or not product.active:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Product not found",
        )
    return product
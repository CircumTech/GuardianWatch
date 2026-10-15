from fastapi import (
    APIRouter,
    Depends,
    HTTPException,
    Path,
    Query,
    Request,
    status,
)
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.dependencies import get_current_admin
from app.models.admin_user import AdminUser
from app.models.product import Product
from app.rate_limit import limiter
from app.schemas.admin import ProductCreateRequest, ProductUpdateRequest
from app.schemas.product import PRODUCT_ID_PATTERN, AdminProductOut
from app.services import admin_audit_service

router = APIRouter(prefix="/admin/products", tags=["admin-products"])


@router.get("", response_model=list[AdminProductOut])
@limiter.limit("60/minute")
async def list_all_products(
    request: Request,  # required by @limiter.limit
    page: int = Query(default=0, ge=0),
    limit: int = Query(default=50, ge=1, le=200),
    admin: AdminUser = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    """
    Unlike the public GET /products, this includes inactive products —
    an admin managing the catalog needs to see everything. Returns
    `AdminProductOut`, which adds `active` and audit timestamps the
    storefront view omits.
    """
    result = await db.execute(
        select(Product)
        .order_by(Product.created_at.desc(), Product.id.asc())
        .offset(page * limit)
        .limit(limit)
    )
    return result.scalars().all()


@router.post(
    "",
    status_code=status.HTTP_201_CREATED,
    response_model=AdminProductOut,
)
async def create_product(
    body: ProductCreateRequest,
    admin: AdminUser = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    existing = await db.get(Product, body.id)
    if existing is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="A product with this id already exists",
        )

    product = Product(**body.model_dump())
    db.add(product)

    await admin_audit_service.record(
        db,
        admin,
        action="product.create",
        resource_type="product",
        resource_id=product.id,
        detail={"name": product.name, "price_cents": product.price_cents},
        commit=False,
    )
    await db.commit()
    await db.refresh(product)
    return product


@router.patch("/{product_id}", response_model=AdminProductOut)
async def update_product(
    product_id: str = Path(..., pattern=PRODUCT_ID_PATTERN),
    body: ProductUpdateRequest = ...,
    admin: AdminUser = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    """
    Partial update.

    The slug (`id`) is immutable — `ProductUpdateRequest` does not
    expose it, so a `PATCH` cannot silently break every existing link
    or reference to this product.
    """
    product = await db.get(Product, product_id)
    if product is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Product not found"
        )

    changes = body.model_dump(exclude_unset=True)

    if not changes:
        # Nothing to do. Do not write an audit entry for a no-op patch.
        return product

    for field, value in changes.items():
        setattr(product, field, value)

    await admin_audit_service.record(
        db,
        admin,
        action="product.update",
        resource_type="product",
        resource_id=product.id,
        detail=changes,
        commit=False,
    )
    await db.commit()
    await db.refresh(product)
    return product


@router.delete("/{product_id}", status_code=status.HTTP_204_NO_CONTENT)
async def deactivate_product(
    product_id: str = Path(..., pattern=PRODUCT_ID_PATTERN),
    admin: AdminUser = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    """
    Soft delete — flips `active` to False.

    Devices and Orders both hold a RESTRICT foreign key to Product, so a
    hard delete of a product that has ever been sold or provisioned
    would fail at the database level anyway. Soft delete is also the
    correct behavior: an old product should disappear from the shop, not
    make historical orders unable to display what was bought.

    Idempotent — deactivating an already-inactive product succeeds
    without writing a duplicate audit entry.
    """
    product = await db.get(Product, product_id)
    if product is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Product not found"
        )

    if not product.active:
        # Already inactive — no-op.
        return

    product.active = False

    await admin_audit_service.record(
        db,
        admin,
        action="product.deactivate",
        resource_type="product",
        resource_id=product.id,
        commit=False,
    )
    await db.commit()
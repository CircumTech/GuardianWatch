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
from sqlalchemy.orm import selectinload

from app.database import get_db
from app.dependencies import get_current_admin
from app.models.admin_user import AdminUser
from app.models.device import Device, DeviceStatus
from app.models.product import Product
from app.models.user import User
from app.rate_limit import limiter
from app.schemas.admin import AdminDeviceOut, DeviceProvisionRequest
from app.schemas.product import ProductOut
from app.services import admin_audit_service

router = APIRouter(prefix="/admin/devices", tags=["admin-devices"])

# Slug-like pattern for device IDs. Matches what `generate_device_id`
# produces; keeps a URL path parameter from accepting arbitrary strings.
_DEVICE_ID_PATTERN = r"^GW-[A-Z0-9]{4}-[A-Z0-9]{4}$"


def _to_admin_device_out(
    device: Device, owner_email: str | None
) -> AdminDeviceOut:
    return AdminDeviceOut(
        id=device.id,
        product=ProductOut.model_validate(device.product),
        status=device.status.value,
        owner_user_id=device.owner_user_id,
        owner_email=owner_email,
        firmware_version=device.firmware_version,
        warranty_months=device.warranty_months,
        manufactured_at=device.manufactured_at,
        registered_at=device.registered_at,
    )


@router.get("", response_model=list[AdminDeviceOut])
@limiter.limit("60/minute")
async def list_devices(
    request: Request,  # required by @limiter.limit
    status_filter: DeviceStatus | None = Query(default=None, alias="status"),
    page: int = Query(default=0, ge=0),
    limit: int = Query(default=50, ge=1, le=200),
    admin: AdminUser = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    """
    Support/ops view of every provisioned unit.

    Includes the owner's email (a support agent needs to know who to
    contact about their specific device) but nothing about that owner's
    health data. The boundary is enforced by what fields exist on
    `AdminDeviceOut`, not by a permission check — so an accidental
    field addition to the schema is the only way to leak health data,
    and that requires a deliberate change.

    Paginated: 50 per page by default, 200 max.
    """
    query = (
        select(Device, User.email)
        .outerjoin(User, Device.owner_user_id == User.id)
        .options(selectinload(Device.product))
        .order_by(Device.manufactured_at.desc(), Device.id.asc())
        .offset(page * limit)
        .limit(limit)
    )

    # `DeviceStatus | None` in the Query annotation means FastAPI parses
    # and validates the value before the handler runs — no try/except
    # needed, and the OpenAPI docs list the allowed values.
    if status_filter is not None:
        query = query.where(Device.status == status_filter)

    result = await db.execute(query)
    return [
        _to_admin_device_out(device, email) for device, email in result.all()
    ]


@router.post(
    "/provision",
    status_code=status.HTTP_201_CREATED,
    response_model=list[AdminDeviceOut],
)
async def provision_devices(
    body: DeviceProvisionRequest,
    admin: AdminUser = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    """
    Registers new physical units in the system before they're ever sold —
    the manufacturing-line counterpart to a customer later claiming one
    via POST /devices/register.

    Quantity bounds are enforced by `DeviceProvisionRequest` at the
    schema level; this handler does not re-validate.
    """
    product = await db.get(Product, body.product_id)
    if product is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Product not found",
        )

    devices = [
        # Assigning `product=product` (not just `product_id=product.id`)
        # populates the in-memory relationship directly from the object
        # already fetched above — accessing `.product` later (in
        # `_to_admin_device_out`) would otherwise trigger a lazy load,
        # which async SQLAlchemy can't do synchronously during response
        # serialization.
        Device(product=product, warranty_months=body.warranty_months)
        for _ in range(body.quantity)
    ]
    db.add_all(devices)

    # Audit and device rows are written in the same transaction. If
    # either fails, both roll back — the alternative (audit after
    # commit) leaves a window where devices exist without a matching
    # audit entry.
    await admin_audit_service.record(
        db,
        admin,
        action="device.provision",
        resource_type="product",
        resource_id=product.id,
        detail={
            "quantity": body.quantity,
            "device_ids": [d.id for d in devices],
        },
        commit=False,
    )
    await db.commit()

    return [_to_admin_device_out(d, None) for d in devices]


@router.post("/{device_id}/deactivate", response_model=AdminDeviceOut)
async def deactivate_device(
    device_id: str = Path(..., pattern=_DEVICE_ID_PATTERN),
    admin: AdminUser = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    """
    Blocks a device id from being registered or re-registered without
    deleting its history. Used for lost, stolen, or recalled units.

    Idempotent — calling on an already-deactivated device is a no-op
    that still returns 200. `POST /{device_id}/reactivate` is the
    reverse operation.
    """
    result = await db.execute(
        select(Device, User.email)
        .outerjoin(User, Device.owner_user_id == User.id)
        .where(Device.id == device_id)
        .options(selectinload(Device.product))
    )
    row = result.first()
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Device not found",
        )
    device, owner_email = row

    if device.status != DeviceStatus.deactivated:
        device.status = DeviceStatus.deactivated

        await admin_audit_service.record(
            db,
            admin,
            action="device.deactivate",
            resource_type="device",
            resource_id=device.id,
            commit=False,
        )
        await db.commit()
        await db.refresh(device)

    return _to_admin_device_out(device, owner_email)


@router.post("/{device_id}/reactivate", response_model=AdminDeviceOut)
async def reactivate_device(
    device_id: str = Path(..., pattern=_DEVICE_ID_PATTERN),
    admin: AdminUser = Depends(get_current_admin),
    db: AsyncSession = Depends(get_db),
):
    """
    Reverses a deactivation. Only valid from `deactivated` status — a
    device that is currently `registered` cannot be "reactivated" and
    vice versa.

    After reactivation the device returns to `unregistered` (not
    `registered`), so the previous owner must re-pair it. This is
    intentional: deactivation implies the previous pairing is no longer
    trusted (lost/stolen/RMA), and silently restoring the old owner
    would defeat the point.
    """
    result = await db.execute(
        select(Device, User.email)
        .outerjoin(User, Device.owner_user_id == User.id)
        .where(Device.id == device_id)
        .options(selectinload(Device.product))
    )
    row = result.first()
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Device not found",
        )
    device, owner_email = row

    if device.status != DeviceStatus.deactivated:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Device is {device.status.value}, not deactivated.",
        )

    device.status = DeviceStatus.unregistered
    device.owner_user_id = None
    device.registered_at = None

    await admin_audit_service.record(
        db,
        admin,
        action="device.reactivate",
        resource_type="device",
        resource_id=device.id,
        commit=False,
    )
    await db.commit()
    await db.refresh(device)

    return _to_admin_device_out(device, None)
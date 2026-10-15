import datetime as dt

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.database import get_db
from app.dependencies import get_current_user
from app.models.device import Device, DeviceStatus
from app.models.user import User
from app.rate_limit import limiter
from app.schemas.device import DeviceLookupOut, DeviceOut, DeviceRegisterRequest

router = APIRouter(prefix="/devices", tags=["devices"])


async def _get_device_with_product(db: AsyncSession, device_id: str) -> Device | None:
    """
    Deliberately `execute(select(...))` rather than `db.get(Device, id,
    options=[...])`: `get()` checks the session's identity map first and,
    if the row is already attached to *this* session from an earlier
    query (common in request flows that touch the same device twice, and
    in tests that seed data through the same session the app uses),
    returns that cached instance as-is — silently ignoring the
    `selectinload` option and leaving `product` unloaded. A real SELECT
    doesn't take that shortcut.
    """
    result = await db.execute(
        select(Device)
        .where(Device.id == device_id)
        .options(selectinload(Device.product))
    )
    return result.scalar_one_or_none()


# ─────────────────────────────────────────────────────────────────────────
# Lookup (public)
# ─────────────────────────────────────────────────────────────────────────


@router.get("/lookup/{device_id}", response_model=DeviceLookupOut)
@limiter.limit("30/minute")
async def lookup_device(
    request: Request,  # required by @limiter.limit
    device_id: str,
    db: AsyncSession = Depends(get_db),
):
    """
    Public device lookup for the company site's authenticity page.

    Never exposes who owns a device — see `DeviceLookupOut`'s docstring.

    Rate-limited per IP because a device ID is by design shareable
    (like a serial number), which means it must be assumed enumerable.
    The rate limit bounds brute-force probing; the ID space itself
    should also be random, not sequential.
    """
    device = await _get_device_with_product(db, device_id.strip().upper())
    if device is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=(
                "No device found with that ID. Double-check the code "
                "printed under the strap."
            ),
        )
    return device


# ─────────────────────────────────────────────────────────────────────────
# List owned devices
# ─────────────────────────────────────────────────────────────────────────


@router.get("/mine", response_model=list[DeviceOut])
async def list_my_devices(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Device)
        .where(Device.owner_user_id == user.id)
        .options(selectinload(Device.product))
    )
    return result.scalars().all()


# ─────────────────────────────────────────────────────────────────────────
# Registration
# ─────────────────────────────────────────────────────────────────────────


@router.post("/register", response_model=DeviceOut)
async def register_device(
    body: DeviceRegisterRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    Claims a device for the signed-in user.

    Registration is a compare-and-swap on `status = unregistered`:

      - An `UPDATE ... WHERE status = unregistered` is atomic. Two
        concurrent requests for the same device cannot both succeed.
      - The loser sees `rowcount == 0` and is told the device is
        already taken.
      - A repeat request from the *same* user is idempotent — returns
        the existing device, not 409.
      - A `deactivated` device cannot be claimed by anyone — this
        represents a unit reported lost, stolen, or returned under RMA.
        Only an admin can reactivate one.
    """
    device_id = body.device_id.strip().upper()

    existing = await _get_device_with_product(db, device_id)
    if existing is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No device found with that ID.",
        )

    # Deactivated devices are refused regardless of who is asking.
    # Reactivation is an admin-only operation.
    if existing.status == DeviceStatus.deactivated:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                "This device has been deactivated. Contact support if "
                "you believe this is an error."
            ),
        )

    # Already ours? Idempotent success.
    if existing.owner_user_id == user.id:
        return existing

    # Already owned by someone else? Fail fast.
    if existing.status == DeviceStatus.registered:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="This device is already registered to another account.",
        )

    # Atomic claim: only succeeds if the device is still unregistered.
    result = await db.execute(
        update(Device)
        .where(
            Device.id == device_id,
            Device.status == DeviceStatus.unregistered,
        )
        .values(
            owner_user_id=user.id,
            status=DeviceStatus.registered,
            registered_at=dt.datetime.now(dt.timezone.utc),
        )
    )

    if result.rowcount == 0:
        await db.rollback()
        fresh = await _get_device_with_product(db, device_id)
        if fresh is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="No device found with that ID.",
            )
        if fresh.status == DeviceStatus.deactivated:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="This device has been deactivated.",
            )
        if fresh.owner_user_id == user.id:
            return fresh
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="This device is already registered to another account.",
        )

    await db.commit()

    device = await _get_device_with_product(db, device_id)
    if device is None:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Device claim succeeded but re-fetch failed.",
        )
    return device


# ─────────────────────────────────────────────────────────────────────────
# Reset registration
# ─────────────────────────────────────────────────────────────────────────


@router.post("/{device_id}/reset", response_model=DeviceOut)
async def reset_device_registration(
    device_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    Cloud-side counterpart to the device's own long-press-power-button
    reset.

    Unlinks the device from its current owner so it can be re-registered.
    Only the current owner can do this. Uses the same atomic
    compare-and-swap as registration: the `UPDATE ... WHERE
    owner_user_id = user.id` is safe under concurrent requests.
    """
    normalized_id = device_id.strip().upper()

    existing = await _get_device_with_product(db, normalized_id)
    if existing is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No device found with that ID.",
        )
    if existing.owner_user_id != user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only the registered owner can reset this device.",
        )

    # Atomic unlink: only succeeds if this user is still the owner.
    result = await db.execute(
        update(Device)
        .where(
            Device.id == normalized_id,
            Device.owner_user_id == user.id,
        )
        .values(
            owner_user_id=None,
            status=DeviceStatus.unregistered,
            registered_at=None,
        )
    )

    if result.rowcount == 0:
        # Ownership changed between our SELECT and this UPDATE — someone
        # else reset or claimed the device.
        await db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Device ownership changed. Refresh and try again.",
        )

    await db.commit()

    device = await _get_device_with_product(db, normalized_id)
    if device is None:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Reset succeeded but re-fetch failed.",
        )
    return device
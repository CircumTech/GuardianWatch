"""
Profile and account management.


`DELETE /me` implements the backend half of the NDPA 2023 right to
erasure. The mobile app already deletes the Firebase account and the
local SQLite database (`AuthService.deleteAccount`); this endpoint is
what removes the backend's copy of the user's readings, insights, and
subscription audit trail.

The mobile app must call `DELETE /me` **before** calling Firebase's
`user.delete()`. Once Firebase deletes the account, the JWT is invalid
and this endpoint becomes unreachable — the order matters.
"""
import logging

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import update as sa_update
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.dependencies import get_current_user
from app.models.device import Device, DeviceStatus
from app.models.user import User
from app.schemas.user import UserOut, UserProfileUpdate

logger = logging.getLogger("guardianwrist.users")

router = APIRouter(tags=["users"])


@router.get("/me", response_model=UserOut)
async def get_me(user: User = Depends(get_current_user)):
    """
    Returns the signed-in user's profile.

    Includes `premium` and `premium_expires_at` so mobile can display
    subscription status without a second request.
    """
    return UserOut.model_validate(user)


@router.patch("/me", response_model=UserOut)
async def update_me(
    body: UserProfileUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    Updates the signed-in user's profile.

    Only fields the client explicitly sent are applied
    (`exclude_unset=True`). Sending `{"age": null}` explicitly clears
    the field. This matches the mobile app's behavior — see
    `ProfileScreen._saveProfile`, which sends an empty string for
    cleared fields that the schema maps to `null`.
    """
    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(user, field, value)
    await db.commit()
    await db.refresh(user)
    return UserOut.model_validate(user)


@router.delete("/me", status_code=status.HTTP_204_NO_CONTENT)
async def delete_me(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    Permanently deletes the signed-in user and all associated data.

    Cascade rules on `User.readings`, `User.insights`, and
    `User.subscriptions` (all `ondelete="CASCADE"`) remove every child
    row. Devices are unlinked rather than deleted — a physical watch
    can be re-registered by a new owner, and its serial number should
    remain queryable via the public lookup endpoint.

    Called by the mobile client BEFORE Firebase account deletion. Once
    Firebase deletes the account, this endpoint becomes unreachable.

    Returns 204 (No Content) on success.
    """
    user_id = user.id

    # Unlink any devices the user owns so the hardware can be reused.
    # (Cascade would delete them, but a watch is not user data — it's
    # physical property that can change hands.)
    await db.execute(
        sa_update(Device)
        .where(Device.owner_user_id == user_id)
        .values(
            owner_user_id=None,
            status=DeviceStatus.unregistered,
            registered_at=None,
        )
    )

    # Deleting the User row cascades to readings / insights /
    # subscriptions via the FK constraints.
    await db.delete(user)
    await db.commit()

    logger.info("User deleted: %s", user_id)
"""
Admin login — email + password, not Firebase.

There is deliberately no public "register as admin" endpoint: admin
accounts are created exclusively via `scripts/create_admin.py`, run by
whoever controls the deployment. A self-service admin signup form would
defeat the entire point of having a restricted admin tier.
"""
import datetime as dt
import logging

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.database import get_db
from app.dependencies import get_current_admin
from app.models.admin_user import AdminUser
from app.rate_limit import limiter
from app.schemas.admin import AdminLoginRequest, AdminOut, AdminTokenResponse
from app.security import create_admin_token, verify_password

logger = logging.getLogger("guardianwrist.admin_auth")

router = APIRouter(prefix="/admin/auth", tags=["admin-auth"])

# Precomputed bcrypt hash of a random string. Used to equalize the
# response time between "no such admin" and "wrong password" — without
# it, the no-such-admin path returns immediately and reveals that the
# email doesn't exist. Same value every request so `verify_password`
# performs one bcrypt comparison regardless of which branch is taken.
_HASH = "$2b$12$C6UzMDM.H6dfI/f/IKcEeO2ovYFYqrLnDBJUY6c0gYtQpP0R3EqLK"


@router.post("/login", response_model=AdminTokenResponse)
@limiter.limit(get_settings().RATE_LIMIT_AUTH)
async def admin_login(
    request: Request,  # required by @limiter.limit
    body: AdminLoginRequest,
    db: AsyncSession = Depends(get_db),
):
    """
    Admin login.

    Rate-limited with the same tight limit as customer login —
    credential-checking endpoints are exactly what brute-force attempts
    target.

    Every failure path (no such admin, wrong password, deactivated
    account) returns the same 401 with the same message. The timing of
    the response is also normalized: `verify_password` runs against a
    dummy hash when the account does not exist, so the bcrypt cost is
    paid on every path.
    """
    normalized_email = body.email.strip().lower()

    result = await db.execute(
        select(AdminUser).where(AdminUser.email == normalized_email)
    )
    admin = result.scalar_one_or_none()

    # Always run bcrypt — even when the account doesn't exist — so the
    # response time cannot be used to infer existence.
    password_hash = admin.hashed_password if admin is not None else _HASH
    password_ok = verify_password(body.password, password_hash)

    # `is_active` is checked AFTER the password comparison, so a
    # deactivated admin goes through exactly the same code path
    # (and takes the same time) as an active one with a wrong
    # password.
    now = dt.datetime.now(dt.timezone.utc)
    if admin is not None and admin.locked_until is not None and admin.locked_until > now:
        wait = int((admin.locked_until - now).total_seconds())
        logger.warning(
            "Locked admin login attempt for %s (request_id=%s, wait=%ds)",
            normalized_email,
            getattr(request.state, "request_id", "-"),
            wait,
        )
        # 401 with the same generic message — do not reveal the lockout.
        raise HTTPException(401, "Invalid email or password")

    password_hash = admin.hashed_password if admin is not None else _DUMMY_HASH
    password_ok = verify_password(body.password, password_hash)

    if admin is None or not password_ok or not admin.is_active:
        if admin is not None:
            admin.failed_login_attempts += 1
            if admin.failed_login_attempts >= 5:
                admin.locked_until = now + dt.timedelta(minutes=15)
                admin.failed_login_attempts = 0
                logger.warning(
                    "Admin account locked for 15 min: %s",
                    normalized_email,
                )
            await db.commit()

        logger.warning(
            "Failed admin login attempt for %s (request_id=%s)",
            normalized_email,
            getattr(request.state, "request_id", "-"),
        )
        raise HTTPException(401, "Invalid email or password")

    # Success — clear counters.
    admin.failed_login_attempts = 0
    admin.locked_until = None
    admin.last_login_at = now
    await db.commit()

    token, expires_in = create_admin_token(
        admin.id,
        extra_claims={"email": admin.email} if admin.email else {},
    )

    logger.info(
        "Admin login: %s (request_id=%s)",
        admin.id,
        getattr(request.state, "request_id", "-"),
    )

    return AdminTokenResponse(
        access_token=token,
        expires_in=expires_in,
        admin=AdminOut.model_validate(admin),
    )


@router.get("/me", response_model=AdminOut)
async def get_current_admin_info(admin: AdminUser = Depends(get_current_admin)):
    return admin
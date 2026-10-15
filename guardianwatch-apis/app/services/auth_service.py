"""
Handles POST /auth/token: verify the Firebase ID token, upsert the local
`User` row (this API's own Postgres table — separate from, and not a
replacement for, the Firestore `users/{uid}` doc `auth_service.dart`
already writes to), and mint this API's own JWT.
"""
from __future__ import annotations

import datetime as dt
import logging

from fastapi import HTTPException, status
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app import security
from app.models.user import User

logger = logging.getLogger("guardianwrist.auth")

# Threshold for the last_login_at write. Firebase ID tokens refresh hourly,
# so without this every refresh would rewrite the row.
_LOGIN_TIMESTAMP_REFRESH = dt.timedelta(hours=1)


async def exchange_firebase_token(
    db: AsyncSession, id_token: str
) -> tuple[User, str, int]:
    """
    Verifies a Firebase ID token, upserts the local `User` row, and
    returns `(user, guardian_jwt, expires_in_seconds)`.

    Raises HTTP 401 if the Firebase token is invalid/expired/revoked, and
    HTTP 500 only if a race in user creation could not be recovered from.
    """
    # Calls through the `security` module object (not `from app.security
    # import verify_firebase_id_token`) so tests can patch
    # `app.security.verify_firebase_id_token` regardless of import order.
    claims = security.verify_firebase_id_token(id_token)

    uid = claims.get("uid")
    if not uid:
        # Firebase always includes `uid`. Its absence means the token was
        # not what we thought it was — treat as an auth failure, not 500.
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired session",
        )

    email = claims.get("email")
    name = claims.get("name")
    picture = claims.get("picture")
    email_verified = bool(claims.get("email_verified", False))
    now = dt.datetime.now(dt.timezone.utc)

    user = await db.get(User, uid)

    if user is None:
        user = await _create_user(
            db,
            uid=uid,
            email=email,
            name=name,
            picture=picture,
            email_verified=email_verified,
            now=now,
        )
    else:
        _apply_claim_updates(
            user,
            email=email,
            name=name,
            picture=picture,
            email_verified=email_verified,
            now=now,
        )
        await db.commit()
        await db.refresh(user)

    # Only embed `email` in the JWT if we actually have one — otherwise the
    # token carries a `null` claim that adds no value.
    extra: dict[str, object] = {}
    if email:
        extra["email"] = email

    token, expires_in = security.create_access_token(subject=uid, extra_claims=extra)

    logger.info(
        "Firebase token exchanged for user=%s (created=%s)",
        uid,
        user.created_at == now,
    )

    return user, token, expires_in


async def _create_user(
    db: AsyncSession,
    *,
    uid: str,
    email: str | None,
    name: str | None,
    picture: str | None,
    email_verified: bool,
    now: dt.datetime,
) -> User:
    """
    Creates the local User row.

    Handles the concurrent-creation race: two simultaneous /auth/token
    calls for the same Firebase UID both observe `user is None` and both
    try to insert. The second insert collides on the primary key. We
    roll back and take the update path instead of returning 500.
    """
    user = User(
        id=uid,
        email=email,
        display_name=name,
        photo_url=picture,
        email_verified=email_verified,
        created_at=now,
        last_login_at=now,
    )
    db.add(user)

    try:
        await db.commit()
        await db.refresh(user)
        return user
    except IntegrityError:
        # Concurrent insert won the race. Roll back this session and
        # re-fetch the row the other request committed.
        await db.rollback()
        existing = await db.get(User, uid)
        if existing is None:
            # Should not happen — the IntegrityError came from this table
            # on this PK. If we still can't find it, something is wrong
            # with the DB and we want a 500 rather than silent misbehavior.
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="User creation race could not be resolved",
            )

        _apply_claim_updates(
            existing,
            email=email,
            name=name,
            picture=picture,
            email_verified=email_verified,
            now=now,
        )
        await db.commit()
        await db.refresh(existing)
        return existing


def _apply_claim_updates(
    user: User,
    *,
    email: str | None,
    name: str | None,
    picture: str | None,
    email_verified: bool,
    now: dt.datetime,
) -> None:
    """
    Copies Firebase claims onto the local User row. Only overwrites fields
    when the claim is present — a Firebase sign-in without a photo should
    not blank out a photo the user set elsewhere.
    """
    if email:
        user.email = email
    if name:
        user.display_name = name
    if picture:
        user.photo_url = picture

    user.email_verified = email_verified

    # Throttle the last_login_at write. Firebase refreshes the ID token
    # roughly hourly and mobile re-exchanges on every 401, so writing this
    # unconditionally means a DB write on the app's hottest auth path.
    if (
        user.last_login_at is None
        or (now - user.last_login_at) > _LOGIN_TIMESTAMP_REFRESH
    ):
        user.last_login_at = now
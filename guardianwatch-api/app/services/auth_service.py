"""
Handles POST /auth/token: verify the Firebase ID token, upsert the local
`User` row (this API's own Postgres table — separate from, and not a
replacement for, the Firestore `users/{uid}` doc `auth_service.dart`
already writes to), and mint this API's own JWT.
"""
from __future__ import annotations

import datetime as dt

from sqlalchemy.ext.asyncio import AsyncSession

from app.models.user import User
from app import security


async def exchange_firebase_token(db: AsyncSession, id_token: str) -> tuple[User, str, int]:
    # Calls through the `security` module object (not `from app.security
    # import verify_firebase_id_token`) so `unittest.mock.patch
    # ("app.security.verify_firebase_id_token")` reliably intercepts this
    # regardless of module import order — a direct name import binds its
    # own reference at import time that a later patch on the origin
    # module won't touch. See tests/conftest.py.
    claims = security.verify_firebase_id_token(id_token)

    uid: str = claims["uid"]
    email = claims.get("email")
    name = claims.get("name")
    picture = claims.get("picture")
    email_verified = bool(claims.get("email_verified", False))
    now = dt.datetime.now(dt.timezone.utc)

    user = await db.get(User, uid)
    if user is None:
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
    else:
        user.email = email or user.email
        user.display_name = name or user.display_name
        user.photo_url = picture or user.photo_url
        user.email_verified = email_verified
        user.last_login_at = now

    await db.commit()
    await db.refresh(user)

    token, expires_in = security.create_access_token(subject=uid, extra_claims={"email": email})
    return user, token, expires_in

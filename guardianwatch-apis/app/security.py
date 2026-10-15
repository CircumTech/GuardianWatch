"""
Two separate concerns live here, both called "auth" but distinct:

1. Firebase ID token verification — proves the person is who Firebase says
   they are. This is the SAME token `auth_service.dart` already gets from
   `FirebaseAuth.instance` on sign-in.
2. Backend JWT issuance — what THIS API actually checks on every other
   request (`Authorization: Bearer <token>`), minted by POST /auth/token
   after step 1 succeeds.
"""
from __future__ import annotations

import datetime as dt
import logging
from typing import Any

import bcrypt
import jwt
from fastapi import HTTPException, status

from app.config import get_settings

settings = get_settings()
_logger = logging.getLogger("guardianwrist.security")

_firebase_app = None  # lazy singleton — see get_firebase_app()


def get_firebase_app():
    """
    Initializes the Firebase Admin SDK on first use rather than at import
    time, so the rest of the API (docs, /health, etc.) still comes up
    cleanly even if credentials aren't configured yet in local dev.
    """
    global _firebase_app
    if _firebase_app is not None:
        return _firebase_app

    import firebase_admin
    from firebase_admin import credentials

    if firebase_admin._apps:
        _firebase_app = firebase_admin.get_app()
        return _firebase_app

    if settings.FIREBASE_CREDENTIALS_PATH:
        cred = credentials.Certificate(settings.FIREBASE_CREDENTIALS_PATH)
    else:
        cred = credentials.ApplicationDefault()

    _firebase_app = firebase_admin.initialize_app(
        cred, options={"projectId": settings.FIREBASE_PROJECT_ID}
    )
    return _firebase_app


def verify_firebase_id_token(id_token: str) -> dict[str, Any]:
    """
    Verifies a Firebase ID token and returns its decoded claims.

    Raises HTTP 401 on anything invalid/expired/revoked. Configuration
    problems (missing service account, wrong project, etc.) also surface
    as 401 to the caller — the distinction is logged for operators only,
    and the caller never sees the underlying exception message.
    """
    from firebase_admin import auth as firebase_auth

    try:
        get_firebase_app()
        return firebase_auth.verify_id_token(id_token, check_revoked=True)
    except Exception as exc:  # noqa: BLE001 — deliberately broad
        # Log the real cause for operators, but do not reflect it to the
        # caller. A malformed token, an expired one, a revoked one, and
        # an admin-SDK misconfiguration all look identical from outside.
        _logger.warning("Firebase ID token verification failed: %r", exc)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired session",
        ) from exc


def create_access_token(
    subject: str, extra_claims: dict[str, Any] | None = None
) -> tuple[str, int]:
    """Mints this API's own JWT. Returns (token, expires_in_seconds)."""
    now = dt.datetime.now(dt.timezone.utc)
    expires_delta = dt.timedelta(minutes=settings.JWT_EXPIRE_MINUTES)
    expire_at = now + expires_delta

    to_encode: dict[str, Any] = {"sub": subject, "iat": now, "exp": expire_at}
    if extra_claims:
        to_encode.update(extra_claims)

    token = jwt.encode(
        to_encode, settings.JWT_SECRET_KEY, algorithm=settings.JWT_ALGORITHM
    )
    return token, int(expires_delta.total_seconds())


def decode_access_token(token: str) -> dict[str, Any]:
    """Decodes/validates this API's own JWT. Raises HTTP 401 on failure."""
    try:
        return jwt.decode(
            token, settings.JWT_SECRET_KEY, algorithms=[settings.JWT_ALGORITHM]
        )
    except jwt.ExpiredSignatureError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Session expired"
        ) from exc
    except jwt.PyJWTError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid session token"
        ) from exc


# ── Admin panel auth — deliberately parallel, not shared ─────────────────


def hash_password(plain_password: str) -> str:
    return bcrypt.hashpw(
        plain_password.encode("utf-8"), bcrypt.gensalt()
    ).decode("utf-8")


def verify_password(plain_password: str, hashed_password: str) -> bool:
    try:
        return bcrypt.checkpw(
            plain_password.encode("utf-8"), hashed_password.encode("utf-8")
        )
    except ValueError:
        return False


def create_admin_token(
    admin_id: str, extra_claims: dict[str, Any] | None = None
) -> tuple[str, int]:
    now = dt.datetime.now(dt.timezone.utc)
    expires_delta = dt.timedelta(minutes=settings.ADMIN_JWT_EXPIRE_MINUTES)
    expire_at = now + expires_delta

    to_encode: dict[str, Any] = {
        "sub": admin_id,
        "scope": "admin",
        "iat": now,
        "exp": expire_at,
    }
    if extra_claims:
        to_encode.update(extra_claims)

    token = jwt.encode(
        to_encode,
        settings.ADMIN_JWT_SECRET_KEY,
        algorithm=settings.JWT_ALGORITHM,
    )
    return token, int(expires_delta.total_seconds())


def decode_admin_token(token: str) -> dict[str, Any]:
    try:
        claims = jwt.decode(
            token,
            settings.ADMIN_JWT_SECRET_KEY,
            algorithms=[settings.JWT_ALGORITHM],
        )
    except jwt.ExpiredSignatureError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Admin session expired",
        ) from exc
    except jwt.PyJWTError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid admin session token",
        ) from exc

    if claims.get("scope") != "admin":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid admin session token",
        )
    return claims
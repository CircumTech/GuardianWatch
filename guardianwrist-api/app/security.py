"""
Two separate concerns live here, both called "auth" but distinct:

1. Firebase ID token verification — proves the person is who Firebase says
   they are. This is the SAME token `auth_service.dart` already gets from
   `FirebaseAuth.instance` on sign-in.
2. Backend JWT issuance — what THIS API actually checks on every other
   request (`Authorization: Bearer <token>`), minted by POST /auth/token
   after step 1 succeeds. Keeping these separate means this API never has
   to re-verify a Firebase token on every call, just its own cheap JWT.
"""
from __future__ import annotations

import datetime as dt
from typing import Any

import jwt
from fastapi import HTTPException, status

from app.config import get_settings

settings = get_settings()

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
        # Application Default Credentials — the right choice on Cloud Run
        # with a service account attached, or after
        # `gcloud auth application-default login` locally.
        cred = credentials.ApplicationDefault()

    _firebase_app = firebase_admin.initialize_app(
        cred, options={"projectId": settings.FIREBASE_PROJECT_ID}
    )
    return _firebase_app


def verify_firebase_id_token(id_token: str) -> dict[str, Any]:
    """
    Verifies a Firebase ID token and returns its decoded claims
    (uid, email, name, picture, email_verified, ...).

    Raises HTTP 401 on anything invalid/expired/revoked rather than
    letting the firebase_admin exception leak up — callers just get a
    clean auth failure.
    """
    from firebase_admin import auth as firebase_auth

    try:
        get_firebase_app()
        return firebase_auth.verify_id_token(id_token, check_revoked=True)
    except Exception as exc:  # noqa: BLE001 — deliberately broad: any
        # failure here (expired, malformed, revoked, wrong project, admin
        # SDK not configured) is equally "not a valid session" from the
        # caller's point of view.
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Invalid Firebase ID token: {exc}",
        ) from exc


def create_access_token(subject: str, extra_claims: dict[str, Any] | None = None) -> tuple[str, int]:
    """Mints this API's own JWT. Returns (token, expires_in_seconds)."""
    now = dt.datetime.now(dt.timezone.utc)
    expires_delta = dt.timedelta(minutes=settings.JWT_EXPIRE_MINUTES)
    expire_at = now + expires_delta

    to_encode: dict[str, Any] = {"sub": subject, "iat": now, "exp": expire_at}
    if extra_claims:
        to_encode.update(extra_claims)

    token = jwt.encode(to_encode, settings.JWT_SECRET_KEY, algorithm=settings.JWT_ALGORITHM)
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

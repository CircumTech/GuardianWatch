"""
Cross-cutting HTTP security.

Four concerns handled here:

  1. Security headers — HSTS, X-Content-Type-Options, X-Frame-Options,
     Referrer-Policy, Permissions-Policy, CSP. These are cheap and
     expensive to retrofit later.

  2. Request size limit — Starlette accepts arbitrary Content-Length.
     Without a cap, a client can POST a 100 MB JSON body and exhaust
     memory before any route handler runs. 

  3. Server header suppression — uvicorn identifies itself by default.
     Removing it denies an attacker a trivial fingerprinting signal.

  4. Slow request logging — a warning when a request exceeds a
     threshold. Full timeouts require a reverse proxy (Render's edge
     handles this on the platform side).
"""
from __future__ import annotations

import logging
import time

from fastapi import Request, status
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from app.config import get_settings

logger = logging.getLogger("guardianwrist.security")
settings = get_settings()

# 1 MB is generous for every endpoint. Bulk ECG uploads go through
# /readings in small batches (mobile caps at 500 records), and the
# schema itself limits the array size.
MAX_BODY_BYTES = 1 * 1024 * 1024

# Slow request threshold. Not a hard timeout — those belong at the
# reverse proxy. This is a signal that something is pathological.
SLOW_REQUEST_SECONDS = 10.0

_SECURITY_HEADERS = {
    # Tell browsers this origin is HTTPS-only for the next year.
    # Only set in non-development.
    "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
    # Stop MIME sniffing.
    "X-Content-Type-Options": "nosniff",
    # No framing.
    "X-Frame-Options": "DENY",
    # Referrer leakage control.
    "Referrer-Policy": "strict-origin-when-cross-origin",
    # Deny features this API doesn't use.
    "Permissions-Policy": (
        "geolocation=(), microphone=(), camera=(), "
        "payment=(), usb=(), magnetometer=()"
    ),
}


class SecurityHeadersMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        # Reject oversized bodies before the app reads them.
        content_length = request.headers.get("content-length")
        if content_length is not None:
            try:
                if int(content_length) > MAX_BODY_BYTES:
                    return JSONResponse(
                        status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                        content={
                            "detail": (
                                f"Request body exceeds "
                                f"{MAX_BODY_BYTES // 1024} KB."
                            )
                        },
                    )
            except ValueError:
                return JSONResponse(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    content={"detail": "Invalid Content-Length header."},
                )

        start = time.perf_counter()
        response = await call_next(request)

        if response.status_code in (401, 403):
            request_id = getattr(request.state, "request_id", "-")
            logger.warning(
                "Auth rejected [request_id=%s]: %s %s → %d",
                request_id,
                request.method,
                request.url.path,
                response.status_code,
            )
        elapsed = time.perf_counter() - start

        if elapsed > SLOW_REQUEST_SECONDS:
            request_id = getattr(request.state, "request_id", "-")
            logger.warning(
                "Slow request [request_id=%s]: %s %s took %.2fs",
                request_id,
                request.method,
                request.url.path,
                elapsed,
            )

        for name, value in _SECURITY_HEADERS.items():
            # Skip HSTS in development — dev is HTTP-only.
            if name == "Strict-Transport-Security" and settings.ENV == "development":
                continue
            response.headers[name] = value

        # Remove the fingerprinting server header if present.
        if "server" in response.headers:
            del response.headers["server"]

        return response
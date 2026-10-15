"""
GuardianWrist API — FastAPI application factory.

Route prefixes are chosen to match `lib/services/api_service.dart`
exactly (`/auth/token`, `/readings`, `/insights/...`,
`/subscription/verify`), so `AppConstants.apiBaseUrl` in the Flutter app
just needs to point here.
"""
from __future__ import annotations

import logging
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from starlette.middleware.base import BaseHTTPMiddleware

from app.config import get_settings
from app.database import init_db
from app.ml.model_registry import build_model_registry
from app.middleware.security_headers import SecurityHeadersMiddleware
from app.rate_limit import limiter
from app.routers import (
    auth, ecg, health, insights, readings, subscription, users,
    products, devices, orders, webhooks,
    admin_auth, admin_products, admin_devices, admin_orders, admin_dashboard,
)

settings = get_settings()

logging.basicConfig(
    level=logging.INFO if not settings.DEBUG else logging.DEBUG,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("guardianwrist")


# ─────────────────────────────────────────────────────────────────────────
# Request ID middleware
# ─────────────────────────────────────────────────────────────────────────
#
# Tags every request with a short correlation ID. Attached to
# request.state for handlers to log, and echoed back in the
# X-Request-ID response header so a client (or the mobile app's
# ApiService, which already sends X-Request-ID on outbound calls) can
# trace a specific request through the logs.


class RequestIDMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        request_id = request.headers.get("x-request-id") or uuid.uuid4().hex[:16]
        request.state.request_id = request_id

        response = await call_next(request)
        response.headers["X-Request-ID"] = request_id
        return response


# ─────────────────────────────────────────────────────────────────────────
# Lifespan
# ─────────────────────────────────────────────────────────────────────────


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Starting %s (env=%s)", settings.APP_NAME, settings.ENV)

    # Loads once, held for the process lifetime — see ml/model_registry.py.
    app.state.models = build_model_registry()
    logger.info("Model status: %s", app.state.models.status())

    if settings.ENV == "development":
        # Convenience for local dev only — use Alembic migrations in
        # staging/production (see alembic/README.md).
        await init_db()
        logger.info("Database tables ensured (development mode)")

    yield

    logger.info("Shutting down %s", settings.APP_NAME)


# ─────────────────────────────────────────────────────────────────────────
# Application factory
# ─────────────────────────────────────────────────────────────────────────


def create_app() -> FastAPI:
    app = FastAPI(
        title=settings.APP_NAME,
        description=(
            "Backend for the GuardianWrist wearable health app — sensor "
            "ingestion, coalesced history, and ML-driven health insights "
            "(HRV/stress, AFib, sleep apnea, fever, fatigue)."
        ),
        version="1.0.0",
        lifespan=lifespan,
        docs_url="/docs",
        redoc_url="/redoc",
        openapi_url="/openapi.json"
    )

    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

    # Registered innermost-first: the last-added middleware is the
    # outermost in the request pipeline. RequestIDMiddleware runs before
    # CORS so even preflight responses carry the correlation header.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.CORS_ORIGINS,
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*", "X-Request-ID"],
        expose_headers=["X-Request-ID"],
    )
    app.add_middleware(RequestIDMiddleware)
    app.add_middleware(SecurityHeadersMiddleware)

    @app.exception_handler(Exception)
    async def unhandled_exception_handler(request: Request, exc: Exception):
        request_id = getattr(request.state, "request_id", "-")
        logger.exception(
            "Unhandled error [request_id=%s] on %s %s",
            request_id,
            request.method,
            request.url.path,
        )
        return JSONResponse(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            content={"detail": "Internal server error"},
        )

    app.include_router(health.router)
    app.include_router(auth.router)
    app.include_router(users.router)
    app.include_router(readings.router)
    app.include_router(insights.router)
    app.include_router(ecg.router)
    app.include_router(subscription.router)
    app.include_router(products.router)
    app.include_router(devices.router)
    app.include_router(orders.router)
    app.include_router(webhooks.router)
    app.include_router(admin_auth.router)
    app.include_router(admin_products.router)
    app.include_router(admin_devices.router)
    app.include_router(admin_orders.router)
    app.include_router(admin_dashboard.router)

    return app


app = create_app()
"""
GuardianWrist API — FastAPI application factory.

Route prefixes are chosen to match `lib/services/api_service.dart`
exactly (`/auth/token`, `/readings`, `/insights/...`,
`/subscription/verify`), so `AppConstants.apiBaseUrl` in the Flutter app
just needs to point here — no Dart changes required for the app to work
against this backend.
"""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.config import get_settings
from app.database import init_db
from app.ml.model_registry import build_model_registry
from app.rate_limit import limiter
from app.routers import auth, ecg, health, insights, readings, subscription, users

settings = get_settings()

logging.basicConfig(
    level=logging.INFO if not settings.DEBUG else logging.DEBUG,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("guardianwrist")


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
    )

    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.CORS_ORIGINS,
        # Auth here is a Bearer header, not a cookie, so credentialed CORS
        # isn't needed — and leaving it off avoids the browser-enforced
        # conflict between `allow_credentials=True` and a wildcard origin.
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.exception_handler(Exception)
    async def unhandled_exception_handler(request: Request, exc: Exception):
        logger.exception("Unhandled error on %s %s", request.method, request.url.path)
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

    return app


app = create_app()

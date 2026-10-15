"""
Liveness and readiness probes.

Two endpoints with distinct responsibilities:

  - `GET /health`  → liveness. Returns 200 while the process is running.
                     Never touches the DB or model registry. A container
                     that returns 200 here is considered alive by the
                     orchestrator, even if it's about to be restarted.

  - `GET /readyz`  → readiness. Verifies the API can actually serve
                     traffic: database reachable, model registry loaded.
                     Returns 503 if either check fails, which tells the
                     orchestrator to hold traffic until the service is
                     truly ready.

The detailed model-status block returned by `registry.status()` is
only exposed when `DEBUG` is on or the caller presents the operator
health token. Public callers get a minimal response — deployment state
is not information the public internet should be able to probe.
"""
import logging

from fastapi import APIRouter, Depends, Header, HTTPException, status
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.database import get_db
from app.dependencies import get_model_registry
from app.ml.model_registry import ModelRegistry

logger = logging.getLogger("guardianwrist.health")
settings = get_settings()

router = APIRouter(tags=["health"])


@router.get("/health")
async def liveness():
    """
    Liveness probe — returns 200 while the process is running.

    Intentionally minimal. A slow or flapping database should not cause
    the orchestrator to kill a healthy process, so this endpoint does
    not check the DB.
    """
    return {"status": "ok"}


@router.get("/readyz")
async def readiness(
    db: AsyncSession = Depends(get_db),
    registry: ModelRegistry = Depends(get_model_registry),
    x_health_token: str | None = Header(default=None, alias="X-Health-Token"),
):
    """
    Readiness probe — verifies the API can serve traffic.

    Checks:
      - Database reachability (SELECT 1)
      - Model registry present (loaded at startup)

    Returns 503 with `{"detail": "Service not ready"}` if either fails.

    When `DEBUG` is on, or the caller presents the operator health
    token, the response includes the detailed `models` block from
    `registry.status()`. Otherwise the response is minimal.
    """
    db_ok = True
    try:
        await db.execute(text("SELECT 1"))
    except Exception as exc:
        logger.error("Readiness: database check failed: %r", exc)
        db_ok = False

    models_ok = registry is not None

    if not (db_ok and models_ok):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Service not ready",
        )

    # Detailed response only for operators.
    operator_health_token = getattr(settings, "HEALTH_TOKEN", None)
    is_operator = (
        settings.DEBUG
        or (operator_health_token and x_health_token == operator_health_token)
    )

    if is_operator:
        return {
            "status": "ok",
            "models": registry.status(),
        }

    return {"status": "ok"}
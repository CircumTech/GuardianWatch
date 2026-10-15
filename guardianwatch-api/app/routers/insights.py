import datetime as dt
import uuid

from fastapi import APIRouter, Body, Depends, Query, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.dependencies import get_current_user, get_model_registry
from app.ml.model_registry import ModelRegistry
from app.models.insight import Insight, InsightSeverity
from app.models.user import User
from app.rate_limit import limiter
from app.schemas.insight import (
    GenerateInsightsRequest,
    InsightOut,
    InsightsSaveRequest,
)
from app.services import insight_service

router = APIRouter(prefix="/insights", tags=["insights"])

# Same-day dedup: two insights with the same title for the same user on
# the same UTC day are the same insight, not two. `generateDailyInsights`
# on the mobile side is user-triggerable multiple times per session, and
# without this the table accumulates one row per tap.
_SAVE_LOOKBACK = dt.timedelta(hours=24)


@router.get("/latest", response_model=list[InsightOut])
async def get_latest_insights(
    limit: int = Query(default=20, ge=1, le=100),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Matches `ApiService.fetchInsights` — bare JSON array, most recent first."""
    result = await db.execute(
        select(Insight)
        .where(Insight.user_id == user.id)
        .order_by(Insight.generated_at.desc())
        .limit(limit)
    )
    return [InsightOut.model_validate(row) for row in result.scalars().all()]


@router.post("/generate", response_model=list[InsightOut])
@limiter.limit("10/minute")
async def generate_insights(
    request: Request,  # required by @limiter.limit — unused otherwise
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
    registry: ModelRegistry = Depends(get_model_registry),
    overrides: GenerateInsightsRequest | None = Body(default=None),
):
    """
    Runs the trained models against the user's recent readings, persists
    the resulting insights, and returns them.

    `overrides` is optional and lenient: the mobile client currently
    sends no body, so `Body(default=None)` accepts the empty case while
    still allowing a future caller to pass per-request overrides.

    Rate-limited tighter than the API default — this endpoint invokes
    four ML models and is the most expensive call in the API.
    """
    return await insight_service.generate_insights_for_user(
        db, user, registry, overrides
    )


@router.post("/save", status_code=201, response_model=list[InsightOut])
async def save_insights(
    body: InsightsSaveRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    Persists insights the client computed on-device.

    Idempotent on (user_id, title, same-day): the mobile client
    regenerates and re-saves on every "Generate" tap, and without
    server-side dedup the same title would be stored once per tap.
    """
    if not body.insights:
        return []

    cutoff = dt.datetime.now(dt.timezone.utc) - _SAVE_LOOKBACK
    existing_result = await db.execute(
        select(Insight).where(
            Insight.user_id == user.id,
            Insight.generated_at >= cutoff,
        )
    )
    existing_by_title: dict[str, Insight] = {
        row.title: row for row in existing_result.scalars().all()
    }

    saved: list[InsightOut] = []

    for ins in body.insights:
        try:
            severity = InsightSeverity(ins.severity)
        except ValueError:
            severity = InsightSeverity.normal

        generated_at = ins.generated_at or dt.datetime.now(dt.timezone.utc)
        existing = existing_by_title.get(ins.title)

        if existing is not None:
            existing.summary = ins.summary
            existing.detail = ins.detail
            existing.severity = severity
            existing.is_premium = ins.is_premium
            existing.recommendation = ins.recommendation
            existing.health_record_id = ins.health_record_id
            existing.algorithm_version = ins.algorithm_version
            existing.generated_at = generated_at
            saved.append(InsightOut.model_validate(existing))
            continue

        row_id = ins.id or str(uuid.uuid4())
        collision = await db.get(Insight, row_id)
        if collision is not None and collision.user_id != user.id:
            row_id = str(uuid.uuid4())

        row = Insight(
            id=row_id,
            user_id=user.id,
            title=ins.title,
            summary=ins.summary,
            detail=ins.detail,
            severity=severity,
            is_premium=ins.is_premium,
            recommendation=ins.recommendation,
            health_record_id=ins.health_record_id,
            algorithm_version=ins.algorithm_version,
            generated_at=generated_at,
        )
        db.add(row)
        existing_by_title[ins.title] = row
        saved.append(InsightOut.model_validate(row))

    await db.flush()
    await db.commit()

    return saved
import datetime as dt
import uuid

from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.dependencies import get_current_user, get_model_registry
from app.ml.model_registry import ModelRegistry
from app.models.insight import Insight, InsightSeverity
from app.models.user import User
from app.schemas.insight import (
    GenerateInsightsRequest,
    InsightOut,
    InsightsSaveRequest,
)
from app.services import insight_service

router = APIRouter(prefix="/insights", tags=["insights"])


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
async def generate_insights(
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
    registry: ModelRegistry = Depends(get_model_registry),
):
    """
    Matches `ApiService.generateInsights` — the app sends no body today,
    so `overrides` is parsed leniently from whatever (if anything) is
    there rather than required. This is the endpoint the Dart app defines
    but has never actually called (`generateDailyInsights()` still
    computes on-device and hits /insights/save instead) — see the
    project README for the suggested one-line change to start using it.

    Runs the real trained models (RandomForest stress, LinearRegression
    fatigue, IsolationForest fever, the AFib CNN) against the user's
    recent `readings`, builds the same insight cards the on-device flow
    would, persists them, and returns them.
    """
    raw_body = await request.body()
    overrides = GenerateInsightsRequest.model_validate_json(raw_body) if raw_body else None

    return await insight_service.generate_insights_for_user(db, user, registry, overrides)


@router.post("/save", status_code=201, response_model=list[InsightOut])
async def save_insights(
    body: InsightsSaveRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    Matches `ApiService.saveInsights` — persists insights the client
    already computed on-device (today's live `generateDailyInsights()`
    path). Either 200 or 201 satisfies the Dart client; 201 is used here
    since this creates resources.
    """
    saved: list[InsightOut] = []
    for ins in body.insights:
        # A fresh server-side id is minted regardless of what the client
        # sent: the Dart client generates ids from
        # `DateTime.now().millisecondsSinceEpoch`, which is unique per
        # device but not guaranteed unique *across* users sharing this
        # table's single global primary key. The client never looks up an
        # insight by the id it generated, so swapping it costs nothing.
        row = Insight(
            id=str(uuid.uuid4()),
            user_id=user.id,
            title=ins.title,
            summary=ins.summary,
            detail=ins.detail,
            severity=InsightSeverity(ins.severity),
            is_premium=ins.is_premium,
            recommendation=ins.recommendation,
            generated_at=ins.generated_at or dt.datetime.now(dt.timezone.utc),
        )
        db.add(row)
        saved.append(InsightOut.model_validate(row))
    await db.commit()
    return saved

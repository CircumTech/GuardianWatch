import datetime as dt

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.reading import (
    HealthRecordOut,
    ReadingsSummaryOut,
    ReadingsUploadRequest,
    ReadingsUploadResponse,
)
from app.services import reading_service

router = APIRouter(prefix="/readings", tags=["readings"])

# Bound the widest range any single request can pull. Coalescing loads
# the whole range into memory (see reading_service.get_coalesced_history),
# so an unbounded range is a DoS vector on the API tier.
_MAX_HISTORY_DAYS = 90


@router.post("", status_code=201, response_model=ReadingsUploadResponse)
async def upload_readings(
    body: ReadingsUploadRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    Batch upload of raw sensor events.

    Accepts both `{"records": [...]}` (current mobile shape) and
    `{"readings": [...]}` (deprecated). Idempotent on `id` so retries
    from the mobile sync queue do not collide.
    """
    readings = body.effective_readings
    if not readings:
        return ReadingsUploadResponse(accepted=0)

    accepted = await reading_service.ingest_readings(db, user.id, readings)
    return ReadingsUploadResponse(accepted=accepted)


@router.get("", response_model=list[HealthRecordOut])
async def get_readings(
    from_: dt.datetime | None = Query(default=None, alias="from"),
    to: dt.datetime | None = Query(default=None),
    page: int = Query(default=0, ge=0),
    limit: int = Query(default=20, ge=1, le=200),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Paginated coalesced history, most recent first. 0-indexed page."""
    end = to or dt.datetime.now(dt.timezone.utc)
    start = from_ or (end - dt.timedelta(days=7))

    if start.tzinfo is None or end.tzinfo is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="from/to must be timezone-aware ISO8601 timestamps",
        )

    if start > end:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="'from' must be earlier than 'to'",
        )

    if (end - start).days > _MAX_HISTORY_DAYS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Range cannot exceed {_MAX_HISTORY_DAYS} days",
        )

    return await reading_service.get_coalesced_history(
        db, user.id, start, end, page, limit
    )


@router.get("/summary", response_model=ReadingsSummaryOut)
async def get_readings_summary(
    from_: dt.datetime | None = Query(default=None, alias="from"),
    to: dt.datetime | None = Query(default=None),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Server-side equivalent of dashboard_provider.dart's avg/min/max math."""
    end = to or dt.datetime.now(dt.timezone.utc)
    start = from_ or (end - dt.timedelta(days=1))

    if (end - start).days > _MAX_HISTORY_DAYS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Range cannot exceed {_MAX_HISTORY_DAYS} days",
        )

    return await reading_service.get_summary(db, user.id, start, end)
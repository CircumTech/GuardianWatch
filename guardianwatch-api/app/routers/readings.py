import datetime as dt

from fastapi import APIRouter, Depends, Query
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


@router.post("", status_code=201, response_model=ReadingsUploadResponse)
async def upload_readings(
    body: ReadingsUploadRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    Matches `ApiService.uploadReadings` — a batch of raw, mostly-partial
    `SensorData` events (see `ble_provider.dart`'s 30-second upload
    queue). 201 on success is required; the Dart client only checks the
    status code, not the body.
    """
    accepted = await reading_service.ingest_readings(db, user.id, body.readings)
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
    """
    Matches `ApiService.fetchHistory` exactly — including `page` being
    0-indexed. Returns coalesced, complete `HealthRecord`-shaped rows
    (see `services/reading_service.py` for why raw partial readings need
    coalescing before they look like this).
    """
    end = to or dt.datetime.now(dt.timezone.utc)
    start = from_ or (end - dt.timedelta(days=7))
    return await reading_service.get_coalesced_history(db, user.id, start, end, page, limit)


@router.get("/summary", response_model=ReadingsSummaryOut)
async def get_readings_summary(
    from_: dt.datetime | None = Query(default=None, alias="from"),
    to: dt.datetime | None = Query(default=None),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Bonus endpoint — not in the current Dart contract. Server-side
    equivalent of the avg/min/max math `dashboard_provider.dart` does
    client-side today."""
    end = to or dt.datetime.now(dt.timezone.utc)
    start = from_ or (end - dt.timedelta(days=1))
    return await reading_service.get_summary(db, user.id, start, end)

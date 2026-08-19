"""
Everything to do with the `readings` table: ingesting raw partial sensor
events, coalescing them into complete `HealthRecord`-shaped rows for
history views, summarizing a range, and gathering the per-metric lookback
windows `insight_service.py` needs (recent ECG, temperature trend, SpO2
overnight trend, daily resting-HR trend).
"""
from __future__ import annotations

import datetime as dt
import statistics
import uuid
from collections import defaultdict

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.reading import Reading
from app.schemas.reading import (
    HealthRecordOut,
    ReadingsSummaryOut,
    SensorDataIn,
)
# How long a carried-forward field value stays valid when coalescing
# partial readings into a complete triple. See `coalesce_health_records`.
COALESCE_STALENESS = dt.timedelta(minutes=5)
# Minimum gap between two emitted coalesced records, so a fully "primed"
# carry-forward state doesn't emit one record per incoming raw reading.
COALESCE_MIN_GAP = dt.timedelta(minutes=1)


async def ingest_readings(
    db: AsyncSession, user_id: str, readings: list[SensorDataIn]
) -> int:
    """
    Persists raw sensor events exactly as uploaded. Matches
    `ApiService.uploadReadings` — a partial `SensorData` per BLE
    notification, most fields null except one. See `Reading` model
    docstring for why we don't try to assemble complete rows here.
    """
    for r in readings:
        db.add(
            Reading(
                id=r.id or str(uuid.uuid4()),
                user_id=user_id,
                heart_rate=r.heart_rate,
                spo2=r.spo2,
                temperature=r.temperature,
                ecg_mv=r.ecg_mv,
                battery=r.battery,
                recorded_at=r.timestamp,
            )
        )
    await db.commit()
    return len(readings)


async def _fetch_raw(
    db: AsyncSession, user_id: str, start: dt.datetime, end: dt.datetime
) -> list[Reading]:
    result = await db.execute(
        select(Reading)
        .where(Reading.user_id == user_id, Reading.recorded_at >= start, Reading.recorded_at <= end)
        .order_by(Reading.recorded_at.asc())
    )
    return list(result.scalars().all())


def _coalesce(readings: list[Reading], visible_from: dt.datetime) -> list[HealthRecordOut]:
    """
    Single-pass carry-forward coalescing: walks readings chronologically,
    remembers the last-seen value (and its time) for each of
    heart_rate/spo2/temperature, and emits a complete record whenever all
    three are simultaneously known and none has gone stale — throttled so
    a fully "primed" state doesn't emit one row per incoming event.
    `visible_from` lets the caller warm up carry-forward state using a
    lookback window without leaking pre-range records into the output.
    """
    hr_val = hr_time = None
    spo2_val = spo2_time = None
    temp_val = temp_time = None
    last_emitted_at: dt.datetime | None = None
    out: list[HealthRecordOut] = []

    for r in readings:
        if r.heart_rate is not None:
            hr_val, hr_time = r.heart_rate, r.recorded_at
        if r.spo2 is not None:
            spo2_val, spo2_time = r.spo2, r.recorded_at
        if r.temperature is not None:
            temp_val, temp_time = r.temperature, r.recorded_at

        if hr_val is None or spo2_val is None or temp_val is None:
            continue
        if r.recorded_at < visible_from:
            continue
        if (
            r.recorded_at - hr_time > COALESCE_STALENESS
            or r.recorded_at - spo2_time > COALESCE_STALENESS
            or r.recorded_at - temp_time > COALESCE_STALENESS
        ):
            continue
        if last_emitted_at is not None and r.recorded_at - last_emitted_at < COALESCE_MIN_GAP:
            continue

        out.append(
            HealthRecordOut(
                id=r.id,
                user_id=r.user_id,
                heart_rate=hr_val,
                spo2=spo2_val,
                temperature=temp_val,
                recorded_at=r.recorded_at,
            )
        )
        last_emitted_at = r.recorded_at

    return out


async def get_coalesced_history(
    db: AsyncSession,
    user_id: str,
    start: dt.datetime,
    end: dt.datetime,
    page: int = 0,
    limit: int = 20,
) -> list[HealthRecordOut]:
    """
    Powers GET /readings. Returns most-recent-first, paginated.
    `page` is 0-indexed — matches `ApiService.fetchHistory`'s default
    (`page = 0`), not the 1-indexed convention used elsewhere in this API.
    """
    # Pad the query window backwards so carry-forward state is already
    # primed by the time we reach `start` — otherwise the first few
    # minutes of any requested range would look artificially sparse.
    padded_start = start - COALESCE_STALENESS
    raw = await _fetch_raw(db, user_id, padded_start, end)
    coalesced = _coalesce(raw, visible_from=start)
    coalesced.reverse()  # most recent first

    offset = max(page, 0) * limit
    return coalesced[offset: offset + limit]


async def get_summary(
    db: AsyncSession, user_id: str, start: dt.datetime, end: dt.datetime
) -> ReadingsSummaryOut:
    """Powers GET /readings/summary — server-side equivalent of the avg/
    min/max math `dashboard_provider.dart` currently does client-side."""
    raw = await _fetch_raw(db, user_id, start, end)
    hr = [r.heart_rate for r in raw if r.heart_rate is not None]
    spo2 = [r.spo2 for r in raw if r.spo2 is not None]
    temp = [r.temperature for r in raw if r.temperature is not None]

    return ReadingsSummaryOut(
        range_from=start,
        range_to=end,
        count=len(raw),
        avg_hr=round(statistics.fmean(hr), 1) if hr else None,
        min_hr=min(hr) if hr else None,
        max_hr=max(hr) if hr else None,
        avg_spo2=round(statistics.fmean(spo2), 1) if spo2 else None,
        min_spo2=min(spo2) if spo2 else None,
        avg_temp=round(statistics.fmean(temp), 2) if temp else None,
    )


# ── lookback windows for insight_service.py ─────────────────────────────

async def fetch_recent_ecg_readings(
    db: AsyncSession, user_id: str, since: dt.datetime, max_readings: int = 200
) -> list[Reading]:
    """Readings carrying an ECG segment, ascending by time, most-recent
    `max_readings` kept — feeds both HRV (RR intervals) and AFib."""
    result = await db.execute(
        select(Reading)
        .where(Reading.user_id == user_id, Reading.recorded_at >= since, Reading.ecg_mv.is_not(None))
        .order_by(Reading.recorded_at.desc())
        .limit(max_readings)
    )
    readings = list(result.scalars().all())
    readings.reverse()  # back to ascending
    return readings


async def fetch_recent_temperatures(
    db: AsyncSession, user_id: str, since: dt.datetime
) -> tuple[list[float], list[float]]:
    """Returns (temperatures, matching_heart_rates) ascending by time —
    the latter only where a heart_rate happens to be non-null in the same
    row, used for the fever model's temp/HR correlation feature."""
    result = await db.execute(
        select(Reading)
        .where(Reading.user_id == user_id, Reading.recorded_at >= since, Reading.temperature.is_not(None))
        .order_by(Reading.recorded_at.asc())
    )
    rows = list(result.scalars().all())
    temps = [r.temperature for r in rows]
    # Only meaningful as a parallel series when every row also has HR —
    # `ml/fever.py` already handles length mismatches, so this is a
    # best-effort pairing rather than a strict requirement.
    hrs = [r.heart_rate for r in rows if r.heart_rate is not None]
    return temps, hrs


async def fetch_recent_spo2(
    db: AsyncSession, user_id: str, since: dt.datetime, max_samples: int = 20000
) -> tuple[list[float], list[float]]:
    """Returns (spo2_values, matching_heart_rates) ascending by time —
    the overnight window used for sleep-apnea scoring."""
    result = await db.execute(
        select(Reading)
        .where(Reading.user_id == user_id, Reading.recorded_at >= since, Reading.spo2.is_not(None))
        .order_by(Reading.recorded_at.asc())
        .limit(max_samples)
    )
    rows = list(result.scalars().all())
    spo2 = [r.spo2 for r in rows]
    hrs = [r.heart_rate for r in rows if r.heart_rate is not None]
    return spo2, hrs


async def fetch_daily_resting_hr_trend(
    db: AsyncSession, user_id: str, since: dt.datetime
) -> list[float]:
    """
    One value per calendar day (UTC) — the day's minimum heart_rate, used
    as a resting-HR proxy. This is a server-side improvement over the
    Dart app's own approach (a 30-reading rolling buffer of *every*
    incoming HR sample, resting or not, that resets whenever the app
    restarts) — here we have full history to pick the daily minimum from,
    which is the standard resting-HR proxy real wearables use.
    Ascending oldest → newest, one entry per day that has data.
    """
    result = await db.execute(
        select(Reading.recorded_at, Reading.heart_rate)
        .where(Reading.user_id == user_id, Reading.recorded_at >= since, Reading.heart_rate.is_not(None))
        .order_by(Reading.recorded_at.asc())
    )
    by_day: dict[dt.date, list[int]] = defaultdict(list)
    for recorded_at, hr in result.all():
        by_day[recorded_at.date()].append(hr)

    days = sorted(by_day.keys())
    return [float(min(by_day[d])) for d in days]

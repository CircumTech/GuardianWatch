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
# partial readings into a complete triple. See `_coalesce`.
COALESCE_STALENESS = dt.timedelta(minutes=5)

# Minimum gap between two emitted coalesced records, so a fully "primed"
# carry-forward state doesn't emit one record per incoming raw reading.
COALESCE_MIN_GAP = dt.timedelta(minutes=1)


# ─────────────────────────────────────────────────────────────────────────
# Ingest
# ─────────────────────────────────────────────────────────────────────────


async def ingest_readings(
    db: AsyncSession, user_id: str, readings: list[SensorDataIn]
) -> int:
    """
    Persists raw sensor events exactly as uploaded.

    Idempotent on `id`. The mobile sync queue retries failed uploads, so
    a naive `INSERT` would raise IntegrityError on any retry and the
    queue would never drain. We instead:

      1. Deduplicate within the incoming batch (a single client retry
         occasionally sends the same id twice in one payload).
      2. Query which of those ids already exist for ANY user — a
         malicious or buggy client cannot overwrite another user's
         reading by guessing an id.
      3. Insert only the ids that are genuinely new.

    Returns the number of rows actually inserted (not the number
    submitted), which is what the mobile client reads from
    `ReadingsUploadResponse.accepted`.
    """
    if not readings:
        return 0

    # 1. Deduplicate within the batch.
    by_id: dict[str, SensorDataIn] = {}
    for r in readings:
        rid = r.id or str(uuid.uuid4())
        by_id[rid] = r

    # 2. Filter out ids that already exist. Note: we do NOT scope by
    #    user_id here — if another user already owns that id, we must
    #    skip it, not overwrite. Ids are client-generated UUIDv4s, so
    #    a collision across users is either a bug or an attack, and
    #    either way we want to ignore, not overwrite.
    existing_result = await db.execute(
        select(Reading.id).where(Reading.id.in_(list(by_id.keys())))
    )
    existing_ids = {row[0] for row in existing_result.all()}

    # 3. Insert only new rows.
    new_rows = 0
    for rid, r in by_id.items():
        if rid in existing_ids:
            continue

        db.add(
            Reading(
                id=rid,
                user_id=user_id,
                heart_rate=r.heart_rate,
                spo2=r.spo2,
                temperature=r.temperature,
                ecg_mv=r.ecg_mv,
                battery=r.battery,
                device_id=r.device_id,
                session_id=r.session_id,
                recorded_at=r.timestamp,
            )
        )
        new_rows += 1

    await db.commit()
    return new_rows


# ─────────────────────────────────────────────────────────────────────────
# Query helpers
# ─────────────────────────────────────────────────────────────────────────


async def _fetch_raw(
    db: AsyncSession,
    user_id: str,
    start: dt.datetime,
    end: dt.datetime,
    *,
    hard_limit: int | None = None,
) -> list[Reading]:
    """
    Pull raw readings in a time window, ascending.

    `hard_limit` is a defensive ceiling applied in addition to any
    caller-side range cap — even with the 90-day range check on the
    endpoint, a user with a high-rate device could still generate
    millions of rows in that window. The caller's range check protects
    the user experience; this protects the API from OOM.
    """
    stmt = (
        select(Reading)
        .where(
            Reading.user_id == user_id,
            Reading.recorded_at >= start,
            Reading.recorded_at <= end,
        )
        .order_by(Reading.recorded_at.asc())
    )
    if hard_limit is not None:
        stmt = stmt.limit(hard_limit)

    result = await db.execute(stmt)
    return list(result.scalars().all())


# ─────────────────────────────────────────────────────────────────────────
# Coalescing
# ─────────────────────────────────────────────────────────────────────────


def _coalesce(
    readings: list[Reading], visible_from: dt.datetime
) -> list[HealthRecordOut]:
    """
    Single-pass carry-forward coalescing.

    Walks readings chronologically, remembering the last-seen value (and
    its timestamp) for each of heart_rate / spo2 / temperature, and
    emits a coalesced record according to this rule:

      - Heart rate is required. It is what defines a "reading" in the
        mobile UI — its History screen renders a row as soon as it has
        an HR, and shows null-safe placeholders for the other metrics.
      - SpO2 and temperature are attached only when fresh (within
        COALESCE_STALENESS of the current sample). When they are stale,
        they are omitted from that row; the mobile `HealthRecord` model
        accepts nulls and the UI handles them.

    Emitted records are throttled so a fully "primed" carry-forward
    state doesn't emit one row per incoming raw reading: consecutive
    emits must be at least COALESCE_MIN_GAP apart.

    `visible_from` lets the caller warm up carry-forward state using a
    lookback window (so the first few minutes of the requested range
    aren't artificially sparse) without leaking pre-range records into
    the output.
    """
    hr_val: int | None = None
    hr_time: dt.datetime | None = None

    spo2_val: int | None = None
    spo2_time: dt.datetime | None = None

    temp_val: float | None = None
    temp_time: dt.datetime | None = None

    last_emitted_at: dt.datetime | None = None
    out: list[HealthRecordOut] = []

    for r in readings:
        # ── Update carry-forward state for whichever metric(s) this
        #    raw reading carries. A BLE notification typically has
        #    only one of these populated; the others stay as they were.
        if r.heart_rate is not None:
            hr_val, hr_time = r.heart_rate, r.recorded_at
        if r.spo2 is not None:
            spo2_val, spo2_time = r.spo2, r.recorded_at
        if r.temperature is not None:
            temp_val, temp_time = r.temperature, r.recorded_at

        # ── Emit conditions ───────────────────────────────────────────
        if hr_val is None or hr_time is None:
            continue
        if r.recorded_at < visible_from:
            continue
        if r.recorded_at - hr_time > COALESCE_STALENESS:
            # HR itself has gone stale — nothing meaningful to emit.
            continue
        if (
            last_emitted_at is not None
            and r.recorded_at - last_emitted_at < COALESCE_MIN_GAP
        ):
            continue

        # ── Attach optional metrics when fresh ────────────────────────
        fresh_spo2: int | None = (
            spo2_val
            if spo2_val is not None
            and spo2_time is not None
            and (r.recorded_at - spo2_time) <= COALESCE_STALENESS
            else None
        )
        fresh_temp: float | None = (
            temp_val
            if temp_val is not None
            and temp_time is not None
            and (r.recorded_at - temp_time) <= COALESCE_STALENESS
            else None
        )

        out.append(
            HealthRecordOut(
                id=r.id,
                user_id=r.user_id,
                heart_rate=hr_val,
                spo2=fresh_spo2,
                temperature=fresh_temp,
                battery=r.battery,
                device_id=r.device_id,
                session_id=r.session_id,
                recorded_at=r.recorded_at,
                created_at=r.created_at,
            )
        )
        last_emitted_at = r.recorded_at

    return out


# ─────────────────────────────────────────────────────────────────────────
# Public: history + summary
# ─────────────────────────────────────────────────────────────────────────


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

    NOTE ON SCALE:
    Coalescing happens in Python, not SQL. A `LAG`-based SQL implementation
    would scale better but is a larger change. To bound the cost, the
    endpoint caps the range at 90 days and this function caps the raw
    fetch at `_MAX_RAW_ROWS`. A `LAG`-based rewrite is a future
    improvement, not a blocker.
    """
    padded_start = start - COALESCE_STALENESS

    raw = await _fetch_raw(
        db, user_id, padded_start, end, hard_limit=_MAX_RAW_ROWS
    )
    coalesced = _coalesce(raw, visible_from=start)
    coalesced.reverse()  # most recent first

    offset = max(page, 0) * limit
    return coalesced[offset : offset + limit]


async def get_summary(
    db: AsyncSession,
    user_id: str,
    start: dt.datetime,
    end: dt.datetime,
) -> ReadingsSummaryOut:
    """
    Powers GET /readings/summary.

    Server-side equivalent of the avg/min/max math
    `dashboard_provider.dart` currently does client-side. Safe to run
    over the same range as history — the endpoint caps it identically.
    """
    raw = await _fetch_raw(
        db, user_id, start, end, hard_limit=_MAX_RAW_ROWS
    )

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


# Defensive ceiling on how many raw rows a single history/summary request
# can pull. The endpoint already caps the *range* at 90 days, but a
# user with a high-rate device could still produce millions of rows in
# that window. This bounds memory regardless of range.
#
# 200_000 rows ≈ 4 hours at 15 Hz, or ~140 days at 1/min. Comfortable
# headroom for every realistic wearable cadence while remaining well
# inside a starter-tier Postgres connection's ability to stream.
_MAX_RAW_ROWS = 200_000


# ─────────────────────────────────────────────────────────────────────────
# Lookback windows for insight_service.py
# ─────────────────────────────────────────────────────────────────────────


async def fetch_recent_ecg_readings(
    db: AsyncSession,
    user_id: str,
    since: dt.datetime,
    max_readings: int = 200,
) -> list[Reading]:
    """
    Readings carrying an ECG segment, ascending by time, most-recent
    `max_readings` kept. Feeds both HRV (RR intervals) and AFib.

    Ordered DESC for the LIMIT, then reversed to ascending — otherwise
    `.limit(N)` with `asc()` would return the *oldest* N, missing the
    recent segment entirely.
    """
    result = await db.execute(
        select(Reading)
        .where(
            Reading.user_id == user_id,
            Reading.recorded_at >= since,
            Reading.ecg_mv.is_not(None),
        )
        .order_by(Reading.recorded_at.desc())
        .limit(max_readings)
    )
    readings = list(result.scalars().all())
    readings.reverse()  # back to ascending
    return readings


async def fetch_recent_temperatures(
    db: AsyncSession,
    user_id: str,
    since: dt.datetime,
) -> tuple[list[float], list[float]]:
    """
    Returns (temperatures, matching_heart_rates) ascending by time.

    The two lists are **index-aligned** — `hrs[i]` is the HR most
    recently seen at or before `temps[i]`. This is required by
    `ml/fever.py`, which computes `np.corrcoef(temps, hrs)` over the
    last 24 samples: unaligned lists of different lengths would raise
    ValueError at inference time.

    When a temperature row has no HR of its own, we carry forward the
    last HR we saw. If no HR has ever been seen in this window, the
    paired value is 0.0 — the model already treats 0 as "unknown", and
    a real HR of 0 is not physiologically possible.
    """
    result = await db.execute(
        select(Reading)
        .where(
            Reading.user_id == user_id,
            Reading.recorded_at >= since,
            Reading.temperature.is_not(None),
        )
        .order_by(Reading.recorded_at.asc())
    )
    rows = list(result.scalars().all())

    temps: list[float] = []
    hrs: list[float] = []
    last_hr: float | None = None

    for r in rows:
        if r.heart_rate is not None:
            last_hr = float(r.heart_rate)
        temps.append(float(r.temperature))
        hrs.append(last_hr if last_hr is not None else 0.0)

    return temps, hrs


async def fetch_recent_spo2(
    db: AsyncSession,
    user_id: str,
    since: dt.datetime,
    max_samples: int = 20_000,
) -> tuple[list[float], list[float]]:
    """
    Returns (spo2_values, matching_heart_rates) ascending by time.

    Keeps the **most recent** `max_samples` when the window would
    otherwise exceed the cap. An overnight window at 1 Hz is ~36,000
    samples; taking the *earliest* 20,000 would miss the morning half
    of the night, which is exactly the segment the sleep-apnea model
    needs most.

    The two lists are index-aligned for the same reason as
    `fetch_recent_temperatures` — a downstream consumer may compute
    correlations and needs matching lengths.
    """
    result = await db.execute(
        select(Reading)
        .where(
            Reading.user_id == user_id,
            Reading.recorded_at >= since,
            Reading.spo2.is_not(None),
        )
        .order_by(Reading.recorded_at.desc())
        .limit(max_samples)
    )
    rows = list(result.scalars().all())
    rows.reverse()  # back to ascending

    spo2: list[float] = []
    hrs: list[float] = []
    last_hr: float | None = None

    for r in rows:
        if r.heart_rate is not None:
            last_hr = float(r.heart_rate)
        spo2.append(float(r.spo2))
        hrs.append(last_hr if last_hr is not None else 0.0)

    return spo2, hrs


async def fetch_daily_resting_hr_trend(
    db: AsyncSession,
    user_id: str,
    since: dt.datetime,
) -> list[float]:
    """
    One value per calendar day (UTC) — the day's minimum heart_rate,
    used as a resting-HR proxy.

    Server-side improvement over the Dart app's own approach (a
    30-reading rolling buffer of *every* incoming HR sample, resting or
    not, that resets whenever the app restarts). Here we have full
    history to pick the daily minimum from, which is the standard
    resting-HR proxy real wearables use.

    Ascending oldest → newest, one entry per day that has data.
    """
    result = await db.execute(
        select(Reading.recorded_at, Reading.heart_rate)
        .where(
            Reading.user_id == user_id,
            Reading.recorded_at >= since,
            Reading.heart_rate.is_not(None),
        )
        .order_by(Reading.recorded_at.asc())
    )

    by_day: dict[dt.date, list[int]] = defaultdict(list)
    for recorded_at, hr in result.all():
        by_day[recorded_at.date()].append(hr)

    days = sorted(by_day.keys())
    return [float(min(by_day[d])) for d in days]
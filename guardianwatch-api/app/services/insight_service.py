"""
Orchestrates POST /insights/generate.

Every insight produced here is a WELLNESS / ENGINEERING indicator.
None is a diagnosis.

The copy, severity thresholds, and premium flags in this file are
byte-for-byte aligned with `insight_provider.dart::generateDailyInsights()`
after the mobile claims-policy review. Any change to either side MUST be
reflected in the other, or the same reading will produce different cards
depending on whether the user tapped "Generate" on-device or on-server.

Rules the copy enforces:
  • No title or summary states or implies a diagnosis.
  • No clinical thresholds (ODI bands, SpO2 cutoffs) are surfaced.
  • No alarmist language about conditions (stroke, blood clots).
  • A short disclaimer closes every detail block.
"""
from __future__ import annotations

import asyncio
import datetime as dt
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.ml import afib as ml_afib
from app.ml import fatigue as ml_fatigue
from app.ml import fever as ml_fever
from app.ml import hrv_stress as ml_hrv
from app.ml import oxygen_trend as ml_oxygen_trend
from app.ml.model_registry import ModelRegistry
from app.models.insight import Insight, InsightSeverity
from app.models.user import User
from app.schemas.insight import GenerateInsightsRequest, InsightOut
from app.services import reading_service

# ── Lookback windows ────────────────────────────────────────────────────
ECG_LOOKBACK = dt.timedelta(minutes=30)
TEMPERATURE_LOOKBACK = dt.timedelta(hours=72)
SPO2_LOOKBACK = dt.timedelta(hours=12)
RESTING_HR_LOOKBACK = dt.timedelta(days=14)

# The AFib TFLite model expects exactly 2500 samples (10s at 250 Hz).
# Mobile zero-pads / trims to the same window via _fitWindow.
AFIB_INPUT_SAMPLES = 2500

# Same-day dedup. Two insights with the same title for the same user on
# the same UTC day are the same insight, not two.
SAME_DAY_WINDOW = dt.timedelta(hours=24)


_DISCLAIMER = (
    "This is a wellness indicator, not a medical diagnosis. "
    "Seek professional evaluation for concerning or persistent symptoms."
)


# ─────────────────────────────────────────────────────────────────────────
# RR extraction
# ─────────────────────────────────────────────────────────────────────────


def _rr_intervals_from_readings(
    ecg_readings: list, sample_rate_hz: float = 250.0
) -> list[float]:
    """
    Derives RR intervals from ECG batches using sample-index spacing.

    Mirrors `insight_model_service.dart::_processRPeak` after the mobile
    claims-policy review. Arrival-time spacing (used in an earlier
    backend revision) added jitter from BLE notification batching and
    produced unusable RR series; sample-index spacing at a fixed assumed
    rate is materially more precise.
    """
    rr_intervals: list[float] = []
    last_peak_global_index: int | None = None
    global_offset = 0
    samples_per_ms = sample_rate_hz / 1000.0

    for reading in ecg_readings:
        segment = reading.ecg_mv or []
        if not segment:
            continue

        peaks = ml_afib.detect_r_peaks(segment)
        for peak_index in peaks:
            global_index = global_offset + peak_index
            if last_peak_global_index is not None:
                sample_diff = global_index - last_peak_global_index
                if sample_diff > 0:
                    rr_ms = sample_diff / samples_per_ms
                    if 300 <= rr_ms <= 2000:
                        rr_intervals.append(rr_ms)
            last_peak_global_index = global_index

        global_offset += len(segment)

    return rr_intervals


# ─────────────────────────────────────────────────────────────────────────
# Insight builders — copy aligned with mobile
# ─────────────────────────────────────────────────────────────────────────


def _build_hrv_insight(hrv) -> dict:
    # Three-tier severity — matches insight_provider.dart.
    if hrv.stress_score >= 70:
        severity = InsightSeverity.warning
    elif hrv.stress_score >= 50:
        severity = InsightSeverity.caution
    else:
        severity = InsightSeverity.normal

    if hrv.stress_score >= 70:
        recommendation = (
            "Consider prioritizing rest, hydration, and stress-management "
            "activities."
        )
    else:
        recommendation = "Maintain healthy sleep and recovery habits."

    return {
        "title": "Stress & Recovery Report",
        "summary": f"Your HRV analysis indicates {hrv.stress_level.lower()} stress.",
        "detail": (
            f"RMSSD: {hrv.rmssd:.1f} ms\n"
            f"SDNN: {hrv.sdnn:.1f} ms\n"
            f"Stress score: {hrv.stress_score:.1f}/100\n\n"
            f"Recovery status: {hrv.recovery_status}.\n\n"
            "HRV is influenced by sleep, exercise, stress, illness, "
            "hydration and other physiological factors.\n\n"
            + _DISCLAIMER
        ),
        "severity": severity,
        # Mobile has this free.
        "is_premium": False,
        "recommendation": recommendation,
    }


def _build_oxygen_trend_insight(trend) -> dict:
    if trend.trend_score >= 60:
        severity = InsightSeverity.warning
    elif trend.trend_score >= 30:
        severity = InsightSeverity.caution
    else:
        severity = InsightSeverity.normal

    return {
        "title": "Overnight Oxygen Trend",
        "summary": f"Oxygen-dip trend level: {trend.trend_level}.",
        "detail": (
            "Oxygen desaturation events per hour (engineering proxy): "
            f"{trend.desaturation_index_proxy:.1f}.\n\n"
            "This is an overnight oxygen-trend indicator based on available "
            "SpO₂ samples. It is not a diagnosis of sleep apnea and should "
            "not replace clinical assessment.\n\n"
            + _DISCLAIMER
        ),
        "severity": severity,
        "is_premium": True,
        "recommendation": trend.recommendation,
    }


def _build_temperature_deviation_insight(fever) -> dict:
    delta = fever.current_temp - fever.baseline_temp

    return {
        "title": "Temperature Above Baseline",
        "summary": (
            f"Your temperature is {delta:.1f} °C above your recent baseline."
        ),
        "detail": (
            f"Current temperature: {fever.current_temp:.1f} °C\n"
            f"Estimated baseline: {fever.baseline_temp:.1f} °C\n\n"
            "This is a personal temperature-trend indicator. It does not "
            "establish the presence or cause of an infection.\n\n"
            + _DISCLAIMER
        ),
        "severity": (
            InsightSeverity.warning if delta >= 2 else InsightSeverity.caution
        ),
        "is_premium": False,
        "recommendation": fever.recommendation,
    }


def _build_hr_elevation_insight(fatigue) -> dict:
    if fatigue.fatigue_score >= 70:
        severity = InsightSeverity.warning
    elif fatigue.fatigue_score >= 40:
        severity = InsightSeverity.caution
    else:
        severity = InsightSeverity.normal

    return {
        "title": "Recovery & Heart-Rate Elevation",
        "summary": f"Current readiness: {fatigue.readiness}.",
        "detail": (
            f"Elevation score: {fatigue.fatigue_score:.1f}/100\n\n"
            f"Recent heart-rate trend: {fatigue.resting_hr_trend}.\n\n"
            "This is based on resting heart-rate trend only, not a "
            "multimodal fatigue measurement.\n\n"
            + _DISCLAIMER
        ),
        "severity": severity,
        # Mobile has this free — do not invert without a matching
        # mobile change and a paywall-product decision.
        "is_premium": False,
        "recommendation": fatigue.recommendation,
    }


def _build_rhythm_irregularity_insight() -> dict:
    return {
        "title": "Irregular Rhythm Pattern",
        "summary": (
            "The analysed ECG segment contains an irregular pattern that "
            "may warrant medical review."
        ),
        "detail": (
            "Guardian Watch identified an irregular rhythm pattern in the "
            "analysed ECG segment.\n\n"
            "This is a screening/engineering indicator, not a diagnosis of "
            "atrial fibrillation. Other rhythm conditions, noise, poor "
            "electrode contact and signal artifacts can affect the result.\n\n"
            + _DISCLAIMER
        ),
        "severity": InsightSeverity.warning,
        "is_premium": True,
        "recommendation": (
            "If you have symptoms or repeated irregular-rhythm results, "
            "seek evaluation from a qualified healthcare professional."
        ),
    }


# ─────────────────────────────────────────────────────────────────────────
# Orchestration
# ─────────────────────────────────────────────────────────────────────────


async def generate_insights_for_user(
    db: AsyncSession,
    user: User,
    registry: ModelRegistry,
    overrides: GenerateInsightsRequest | None,
) -> list[InsightOut]:
    overrides = overrides or GenerateInsightsRequest()
    now = dt.datetime.now(dt.timezone.utc)

    age = overrides.age if overrides.age is not None else user.age
    bmi = overrides.bmi if overrides.bmi is not None else user.bmi
    # Conservative default (6h). Mobile sends the real value when it has
    # one; assuming 7h — the "fully rested" reference point — would bias
    # every insight toward "you're fine".
    sleep_hours = overrides.sleep_hours if overrides.sleep_hours is not None else 6.0

    # ── Gather lookback windows concurrently ─────────────────────────
    ecg_readings, (temps, temp_hrs), (spo2, spo2_hrs), resting_hr_trend = (
        await asyncio.gather(
            reading_service.fetch_recent_ecg_readings(
                db, user.id, now - ECG_LOOKBACK
            ),
            reading_service.fetch_recent_temperatures(
                db, user.id, now - TEMPERATURE_LOOKBACK
            ),
            reading_service.fetch_recent_spo2(
                db, user.id, now - SPO2_LOOKBACK
            ),
            reading_service.fetch_daily_resting_hr_trend(
                db, user.id, now - RESTING_HR_LOOKBACK
            ),
        )
    )

    # ── Prepare AFib input ──────────────────────────────────────────
    rr_intervals = _rr_intervals_from_readings(ecg_readings)

    ecg_flat: list[float] = []
    for reading in ecg_readings[-50:]:  # most recent batches only
        ecg_flat.extend(reading.ecg_mv or [])
    ecg_flat = ecg_flat[-AFIB_INPUT_SAMPLES:]

    # ── Run inference off the event loop ────────────────────────────
    hrv, sleep_trend, fever, fatigue = await asyncio.gather(
        asyncio.to_thread(
            ml_hrv.predict_stress, rr_intervals, registry.stress_model
        ),
        asyncio.to_thread(
            ml_oxygen_trend.predict_sleep_apnea,
            spo2, spo2_hrs,
            age or 30, bmi or 24,
            registry.sleep_apnea_model, registry.sleep_apnea_scaler,
        ),
        asyncio.to_thread(
            ml_fever.detect_fever, temps, temp_hrs, registry.fever_detector
        ),
        asyncio.to_thread(
            ml_fatigue.compute_fatigue,
            resting_hr_trend, overrides.hr_recovery, sleep_hours,
            registry.fatigue_model,
        ),
    )

    afib = (
        await asyncio.to_thread(ml_afib.predict_afib, ecg_flat, registry)
        if ecg_flat
        else None
    )

    # ── Build cards ─────────────────────────────────────────────────
    specs: list[dict] = [
        _build_hrv_insight(hrv),
        _build_oxygen_trend_insight(sleep_trend),
        _build_hr_elevation_insight(fatigue),
    ]
    if fever.is_suspected:
        specs.append(_build_temperature_deviation_insight(fever))
    if afib is not None and afib.is_suspected:
        specs.append(_build_rhythm_irregularity_insight())

    # ── Persist with same-day dedup ─────────────────────────────────
    cutoff = now - SAME_DAY_WINDOW
    existing_result = await db.execute(
        select(Insight).where(
            Insight.user_id == user.id,
            Insight.generated_at >= cutoff,
        )
    )
    existing_by_title: dict[str, Insight] = {
        row.title: row for row in existing_result.scalars().all()
    }

    out: list[InsightOut] = []

    for spec in specs:
        existing = existing_by_title.get(spec["title"])
        version = registry.version_for(spec["title"])

        if existing is not None:
            # Same title within the window — update in place so the
            # server-side id stays stable across regenerations.
            existing.summary = spec["summary"]
            existing.detail = spec["detail"]
            existing.severity = spec["severity"]
            existing.is_premium = spec["is_premium"]
            existing.recommendation = spec["recommendation"]
            existing.algorithm_version = version
            existing.generated_at = now
            out.append(InsightOut.model_validate(existing))
            continue

        row = Insight(
            id=str(uuid.uuid4()),
            user_id=user.id,
            title=spec["title"],
            summary=spec["summary"],
            detail=spec["detail"],
            severity=spec["severity"],
            is_premium=spec["is_premium"],
            recommendation=spec["recommendation"],
            health_record_id=None,  # aggregated insights, no single source
            algorithm_version=version,
            generated_at=now,
        )
        db.add(row)
        existing_by_title[spec["title"]] = row
        out.append(InsightOut.model_validate(row))

    await db.flush()
    await db.commit()

    return out
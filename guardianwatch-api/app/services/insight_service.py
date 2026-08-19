"""
Orchestrates POST /insights/generate: pulls each metric's lookback window
from `readings`, runs it through the matching `ml/` module, and builds
`Insight` cards using the same title/summary/detail copy and
severity/is_premium rules as `generateDailyInsights()` in
insight_provider.dart — so moving computation server-side doesn't change
what the user sees, just what's powering it (real trained models instead
of on-device rules, wherever a model is loaded).

One behavioral addition beyond what `generateDailyInsights()` does today:
an AFib check is folded in here too (gated the same way
`detectAFibFromSegment()` gates its own card — only added if suspected),
since this endpoint already has access to the recent ECG history that
on-device flow doesn't retain across app sessions.
"""
from __future__ import annotations

import datetime as dt
import uuid

import asyncio
from sqlalchemy.ext.asyncio import AsyncSession

from app.ml import afib as ml_afib
from app.ml import fatigue as ml_fatigue
from app.ml import fever as ml_fever
from app.ml import hrv_stress as ml_hrv
from app.ml import sleep_apnea as ml_sleep_apnea
from app.ml.model_registry import ModelRegistry
from app.models.insight import Insight, InsightSeverity
from app.models.user import User
from app.schemas.insight import GenerateInsightsRequest, InsightOut
from app.services import reading_service

# Lookback windows — see docstrings in reading_service.py for the
# per-metric fetch helpers these feed.
ECG_LOOKBACK = dt.timedelta(minutes=30)
TEMPERATURE_LOOKBACK = dt.timedelta(hours=72)
SPO2_LOOKBACK = dt.timedelta(hours=12)
RESTING_HR_LOOKBACK = dt.timedelta(days=14)
AFIB_MAX_SAMPLES = 12_500  # ~50s at 250Hz — bounds preprocessing cost


def _rr_intervals_from_readings(ecg_readings: list) -> list[float]:
    """
    Mirrors `addEcgSample()` in insight_model_service.dart: peaks are
    detected within each batch, but the RR-interval math uses the batch's
    arrival time (`recorded_at`) as a stand-in for per-peak timing, since
    individual samples don't carry their own timestamp over BLE. This
    matches the app's own shipping approximation rather than assuming an
    unverified hardware sample rate. If you confirm a fixed ECG sample
    rate from the Arduino firmware, this can be upgraded to derive RR
    intervals directly from intra-batch sample-index spacing, which would
    be materially more precise.
    """
    rr_intervals: list[float] = []
    last_peak_time: dt.datetime | None = None
    for reading in ecg_readings:
        if not reading.ecg_mv:
            continue
        peaks = ml_afib.detect_r_peaks(reading.ecg_mv)
        if not peaks:
            continue
        peak_time = reading.recorded_at
        if last_peak_time is not None:
            rr_ms = (peak_time - last_peak_time).total_seconds() * 1000
            if 300 < rr_ms < 1500:
                rr_intervals.append(rr_ms)
        last_peak_time = peak_time
    return rr_intervals


def _build_hrv_insight(hrv) -> InsightOut:
    severity = InsightSeverity.warning if hrv.stress_score > 60 else InsightSeverity.normal
    if hrv.stress_score > 60:
        recommendation = "Try deep breathing exercises or meditation to lower stress."
    elif hrv.recovery_status == "Excellent recovery":
        recommendation = "Great job! Your body is recovering well. Consider a challenging workout today."
    else:
        recommendation = "Get adequate sleep and take short breaks throughout the day."

    return InsightOut(
        id=str(uuid.uuid4()),
        title="Stress & Recovery Report",
        summary=f"Your HRV indicates {hrv.stress_level.lower()} stress.",
        detail=(
            f"Your heart rate variability (HRV) score is {hrv.rmssd}ms. "
            f"This places you in the {hrv.recovery_status} category.\n\n"
            "High HRV means your nervous system is balanced and you're recovering well. "
            "Low HRV suggests stress, fatigue, or inadequate recovery."
        ),
        severity=severity.value,
        is_premium=False,
        generated_at=dt.datetime.now(dt.timezone.utc),
        recommendation=recommendation,
    )


def _build_sleep_apnea_insight(risk) -> InsightOut:
    severity = InsightSeverity.warning if risk.risk_score > 40 else InsightSeverity.normal
    return InsightOut(
        id=str(uuid.uuid4()),
        title="Sleep Apnea Risk Assessment",
        summary=f"Your ODI is {risk.odi}. Risk level: {risk.risk_level}.",
        detail=(
            "The Oxygen Desaturation Index (ODI) measures how many times per hour "
            "your blood oxygen drops by 3% or more.\n\n"
            "ODI < 5: Normal\n"
            "ODI 5-15: Mild sleep apnea\n"
            "ODI 15-30: Moderate sleep apnea\n"
            "ODI > 30: Severe sleep apnea"
        ),
        severity=severity.value,
        is_premium=True,
        generated_at=dt.datetime.now(dt.timezone.utc),
        recommendation=risk.recommendation,
    )


def _build_fever_insight(fever) -> InsightOut:
    delta = fever.current_temp - fever.baseline_temp
    return InsightOut(
        id=str(uuid.uuid4()),
        title="Possible Fever Detected",
        summary=f"Your temperature has risen {delta:.1f}\u00b0C above baseline.",
        detail=(
            f"Your current temperature is {fever.current_temp}\u00b0C, "
            f"compared to your baseline of {fever.baseline_temp}\u00b0C.\n\n"
            "A sustained elevation in temperature combined with elevated heart rate "
            "may indicate an infection or inflammatory response."
        ),
        severity=InsightSeverity.warning.value,
        is_premium=False,
        generated_at=dt.datetime.now(dt.timezone.utc),
        recommendation=fever.recommendation,
    )


def _build_fatigue_insight(fatigue) -> InsightOut:
    severity = InsightSeverity.warning if fatigue.fatigue_score > 60 else InsightSeverity.normal
    # Matches the (inverted) is_premium rule in insight_provider.dart:
    # a HIGH fatigue score — the "you need rest" message — stays free for
    # everyone; a LOW score — the "you're ready to push hard" message —
    # is the premium perk.
    is_premium = not (fatigue.fatigue_score > 60)

    return InsightOut(
        id=str(uuid.uuid4()),
        title="Readiness to Train",
        summary=f"Readiness: {fatigue.readiness}",
        detail=(
            f"Your fatigue score is {fatigue.fatigue_score}/100.\n\n"
            f"This is based on your resting heart rate trend ({fatigue.resting_hr_trend}) "
            "and sleep quality.\n\n"
            "A low fatigue score means you're well-rested and ready for high-intensity activity. "
            "A high score suggests you need more recovery."
        ),
        severity=severity.value,
        is_premium=is_premium,
        generated_at=dt.datetime.now(dt.timezone.utc),
        recommendation=fatigue.recommendation,
    )


def _build_afib_insight() -> InsightOut:
    return InsightOut(
        id=str(uuid.uuid4()),
        title="Irregular Heart Rhythm Detected",
        summary="Possible atrial fibrillation (AFib) detected.",
        detail=(
            "Our AI analysis of your ECG detected an irregular rhythm pattern "
            "that may indicate atrial fibrillation.\n\n"
            "AFib is a quivering or irregular heartbeat that can lead to blood clots, "
            "stroke, and other heart complications.\n\n"
            "This is not a medical diagnosis. Please consult your doctor."
        ),
        severity=InsightSeverity.warning.value,
        is_premium=True,
        generated_at=dt.datetime.now(dt.timezone.utc),
        recommendation="Schedule an appointment with your healthcare provider for a proper ECG.",
    )


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
    sleep_hours = overrides.sleep_hours if overrides.sleep_hours is not None else 7.0

    # ── gather every lookback window concurrently ───────────────────────
    ecg_readings, (temps, temp_hrs), (spo2, spo2_hrs), resting_hr_trend = await asyncio.gather(
        reading_service.fetch_recent_ecg_readings(db, user.id, now - ECG_LOOKBACK),
        reading_service.fetch_recent_temperatures(db, user.id, now - TEMPERATURE_LOOKBACK),
        reading_service.fetch_recent_spo2(db, user.id, now - SPO2_LOOKBACK),
        reading_service.fetch_daily_resting_hr_trend(db, user.id, now - RESTING_HR_LOOKBACK),
    )
    rr_intervals = _rr_intervals_from_readings(ecg_readings)
    ecg_flat: list[float] = []
    for reading in ecg_readings[-50:]:  # most recent batches only
        ecg_flat.extend(reading.ecg_mv or [])
    ecg_flat = ecg_flat[-AFIB_MAX_SAMPLES:]

    # ── run inference (off the event loop — sklearn/tflite calls are
    # synchronous CPU work, a few ms each, but no reason to block it) ───
    hrv, sleep_apnea, fever, fatigue = await asyncio.gather(
        asyncio.to_thread(ml_hrv.predict_stress, rr_intervals, registry.stress_model),
        asyncio.to_thread(
            ml_sleep_apnea.predict_sleep_apnea, spo2, spo2_hrs,
            age or 30, bmi or 24, registry.sleep_apnea_model, registry.sleep_apnea_scaler,
        ),
        asyncio.to_thread(ml_fever.detect_fever, temps, temp_hrs, registry.fever_detector),
        asyncio.to_thread(
            ml_fatigue.compute_fatigue, resting_hr_trend, overrides.hr_recovery, sleep_hours,
            registry.fatigue_model,
        ),
    )
    afib = (
        await asyncio.to_thread(ml_afib.predict_afib, ecg_flat, registry)
        if ecg_flat else None
    )

    # ── build insight cards (always-on metrics match generateDailyInsights;
    # fever/AFib stay conditional on suspicion, same as the Dart source) ──
    insights: list[InsightOut] = [
        _build_hrv_insight(hrv),
        _build_sleep_apnea_insight(sleep_apnea),
        _build_fatigue_insight(fatigue),
    ]
    if fever.is_suspected:
        insights.append(_build_fever_insight(fever))
    if afib is not None and afib.is_suspected:
        insights.append(_build_afib_insight())

    # ── persist ──────────────────────────────────────────────────────────
    for ins in insights:
        db.add(
            Insight(
                id=ins.id,
                user_id=user.id,
                title=ins.title,
                summary=ins.summary,
                detail=ins.detail,
                severity=InsightSeverity(ins.severity),
                is_premium=ins.is_premium,
                recommendation=ins.recommendation,
                generated_at=ins.generated_at,
            )
        )
    await db.commit()

    return insights

"""
Fatigue / overtraining monitor.

Ported from `lib/python/fatigue_monitor.py` (LinearRegression), with the
fallback from `insight_model_service.dart::computeFatigue()` when the
model isn't loaded. Output field names already match the Dart
`FatigueResult` model exactly — no remapping needed here (unlike stress
and fever).
"""
from __future__ import annotations

import numpy as np

from app.schemas.health_metrics import FatigueResultOut

MIN_RESTING_HR_DAYS = 7  # matches the Dart app's threshold (stricter than
# the Python script's own internal minimum of 3 — see README for why we
# default to the app's tested behavior).


def _insufficient_data() -> FatigueResultOut:
    return FatigueResultOut(
        fatigue_score=0,
        readiness="Need more data",
        resting_hr_trend="Collect 7 days of resting HR",
        recommendation="Wear your watch while sleeping to track resting heart rate.",
    )


def _readiness_and_recommendation(fatigue_score: float) -> tuple[str, str]:
    if fatigue_score < 30:
        return "High - Ready for intense workout", "Great recovery! You're ready for peak performance."
    if fatigue_score < 60:
        return "Moderate - Light exercise recommended", "Take it easy today. A light walk or stretching is ideal."
    return "Low - Rest day recommended", "Prioritize sleep and recovery. Your body needs rest."


def _rule_based(resting_hr_trend: list[float], sleep_hours: float) -> FatigueResultOut:
    """Verbatim port of the fallback in `computeFatigue()` (insight_model_service.dart)."""
    baseline = float(np.mean(resting_hr_trend[:3]))
    current = float(resting_hr_trend[-1])
    hr_increase_pct = ((current - baseline) / baseline) * 100 if baseline else 0.0

    fatigue_score = float(np.clip(hr_increase_pct * 5, 0, 100))
    sleep_adjustment = max(0.0, (7 - sleep_hours) * 10)
    fatigue_score = float(np.clip(fatigue_score + sleep_adjustment, 0, 100))

    readiness, recommendation = _readiness_and_recommendation(fatigue_score)
    return FatigueResultOut(
        fatigue_score=round(fatigue_score),
        readiness=readiness,
        resting_hr_trend=f"{round(baseline)} → {round(current)} bpm",
        recommendation=recommendation,
    )


def _ml_based(
    resting_hr_trend: list[float],
    hr_recovery: float,
    sleep_hours: float,
    model,
) -> FatigueResultOut:
    """Verbatim port of `compute_fatigue()` in fatigue_monitor.py."""
    baseline_hr = float(np.mean(resting_hr_trend[:3]))
    current_hr = float(resting_hr_trend[-1])

    if len(resting_hr_trend) > 1 and baseline_hr:
        hr_increase = (current_hr - baseline_hr) / baseline_hr
        prev_fatigue = min(100.0, max(0.0, hr_increase * 200))
    else:
        prev_fatigue = 30.0

    features = np.array([[current_hr, hr_recovery, sleep_hours, prev_fatigue]])
    fatigue_score = float(model.predict(features)[0])
    fatigue_score = max(0.0, min(100.0, fatigue_score))

    hr_trend_text = f"{baseline_hr:.0f} → {current_hr:.0f} bpm"
    sign = "+" if current_hr > baseline_hr else ""
    increase_text = f" ({sign}{current_hr - baseline_hr:.0f} bpm)"

    readiness, recommendation = _readiness_and_recommendation(fatigue_score)
    return FatigueResultOut(
        fatigue_score=round(fatigue_score, 1),
        readiness=readiness,
        resting_hr_trend=hr_trend_text + increase_text,
        recommendation=recommendation,
    )


def compute_fatigue(
    resting_hr_trend: list[float],
    hr_recovery: float | None = None,
    sleep_hours: float = 7,
    model=None,
) -> FatigueResultOut:
    """Main entry point."""
    if len(resting_hr_trend) < MIN_RESTING_HR_DAYS:
        return _insufficient_data()

    if hr_recovery is None:
        hr_recovery = 20.0  # matches the Python script's own default

    if model is None:
        return _rule_based(resting_hr_trend, sleep_hours)
    return _ml_based(resting_hr_trend, hr_recovery, sleep_hours, model)

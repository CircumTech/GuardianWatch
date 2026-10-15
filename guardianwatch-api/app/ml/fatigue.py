"""
Heart-rate elevation / readiness indicator.

Aligned with mobile's
`insight_model_service.dart::computeHeartRateElevationIndicator` after
the claims-policy review. `readiness`, `recommendation`, and
`resting_hr_trend` strings are byte-for-byte identical to what mobile
shows — so a user who sees an insight on the web frontend sees the same
copy they would see on the phone for the same input.
"""
from __future__ import annotations

import numpy as np

from app.schemas.health_metrics import FatigueResultOut

MIN_RESTING_HR_DAYS = 7


def _insufficient_data() -> FatigueResultOut:
    """Byte-for-byte match with mobile's early return."""
    return FatigueResultOut(
        fatigue_score=0.0,
        readiness="Need more data",
        resting_hr_trend="Collect more resting-heart-rate observations",
        recommendation=(
            "Continue wearing Guardian Watch regularly so a personal "
            "trend can be established."
        ),
    )


def _readiness_and_recommendation(
    fatigue_score: float,
) -> tuple[str, str]:
    """
    Mobile's exact readiness values (`'High'` / `'Moderate'` / `'Low'`)
    and exact recommendation copy. Do not introduce prescriptive
    workout language here without a matching mobile change.
    """
    if fatigue_score < 30:
        return (
            "High",
            "Your recent heart-rate trend does not indicate a large "
            "fatigue signal. Continue your normal recovery routine.",
        )
    if fatigue_score < 60:
        return (
            "Moderate",
            "Consider moderate activity and prioritize recovery.",
        )
    return (
        "Low",
        "Prioritize recovery and monitor how you feel before "
        "strenuous exercise.",
    )


def _rule_based(
    resting_hr_trend: list[float],
    sleep_hours: float | None,
) -> FatigueResultOut:
    """
    Byte-for-byte match with mobile's rule-based fatigue indicator.

    `sleep_hours` is optional; when None, the sleep adjustment is
    skipped entirely (same behavior as mobile's nullable parameter).
    The default `7.0` in earlier code biased every user toward "fine".
    """
    baseline = float(np.mean(resting_hr_trend[-7:]))
    current = float(resting_hr_trend[-1])

    hr_increase_pct = (
        ((current - baseline) / baseline) * 100 if baseline else 0.0
    )

    fatigue_score = float(np.clip(hr_increase_pct * 5, 0, 100))

    if sleep_hours is not None and np.isfinite(sleep_hours):
        sleep_adjustment = max(0.0, (7 - sleep_hours) * 10)
        fatigue_score = float(np.clip(fatigue_score + sleep_adjustment, 0, 100))

    readiness, recommendation = _readiness_and_recommendation(fatigue_score)

    return FatigueResultOut(
        fatigue_score=fatigue_score,
        readiness=readiness,
        # Mobile does not append a delta suffix.
        resting_hr_trend=f"{round(baseline)} → {round(current)} bpm",
        recommendation=recommendation,
    )


def _ml_based(
    resting_hr_trend: list[float],
    hr_recovery: float,
    sleep_hours: float | None,
    model,
) -> FatigueResultOut:
    """
    Linear-regression path. Feature engineering preserved from
    `lib/python/fatigue_monitor.py`.

    Copy and readiness values are normalized to mobile's strings after
    inference — the model produces a numeric score, but the user-facing
    labels must not diverge from what the mobile surface shows.
    """
    baseline_hr = float(np.mean(resting_hr_trend[:3]))
    current_hr = float(resting_hr_trend[-1])

    if len(resting_hr_trend) > 1 and baseline_hr:
        hr_increase = (current_hr - baseline_hr) / baseline_hr
        prev_fatigue = min(100.0, max(0.0, hr_increase * 200))
    else:
        prev_fatigue = 30.0

    # Apply the same sleep adjustment the rule-based path applies. The
    # training script did not include sleep in this position, but
    # ignoring it would make the ML path respond differently to the same
    # sleep input than the rule path does.
    sleep_value = sleep_hours if sleep_hours is not None else 7.0
    features = np.array(
        [[current_hr, hr_recovery, sleep_value, prev_fatigue]]
    )
    fatigue_score = float(model.predict(features)[0])
    fatigue_score = float(np.clip(fatigue_score, 0.0, 100.0))

    readiness, recommendation = _readiness_and_recommendation(fatigue_score)

    return FatigueResultOut(
        fatigue_score=fatigue_score,
        readiness=readiness,
        # No delta suffix — mobile does not append one.
        resting_hr_trend=f"{round(baseline_hr)} → {round(current_hr)} bpm",
        recommendation=recommendation,
    )


def compute_fatigue(
    resting_hr_trend: list[float],
    hr_recovery: float | None = None,
    sleep_hours: float | None = None,
    model=None,
) -> FatigueResultOut:
    """
    Main entry point.

    Note: `sleep_hours` defaults to None, not 7.0. Assuming seven hours
    for every user biases the score toward "well-rested" — the model and
    the rule both treat 7h as the reference point for "no sleep deficit".
    The caller must pass a real value when one is known.
    """
    if len(resting_hr_trend) < MIN_RESTING_HR_DAYS:
        return _insufficient_data()

    if hr_recovery is None:
        hr_recovery = 20.0  # matches the Python reference script's default

    if model is None:
        return _rule_based(resting_hr_trend, sleep_hours)
    return _ml_based(resting_hr_trend, hr_recovery, sleep_hours, model)
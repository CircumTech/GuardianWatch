"""
Overnight oxygen desaturation trend scoring.

This module produces an OXYGEN TREND INDICATOR, not a sleep apnea
diagnosis.

The wrist PPG sensor has no airflow or respiratory-effort channel.
The report is explicit: "Because the baseline device lacks a direct
airflow or respiratory-effort sensor, the initial feature should be
framed as 'sleep breathing risk signal' or 'sleep wellness insight'
during R&D."

Copy, baseline logic, event-detection hysteresis, and severity
thresholds are byte-for-byte aligned with mobile's
`insight_model_service.dart::computeOxygenDesaturationTrend` after the
claims-policy review.

The XGBoost training pipeline in `lib/python/sleep_apena.py` is used
when `sleep_apnea_model.pkl` + `sleep_apnea_scaler.pkl` are present in
`app/models_store/`. Until then, the same rule-based thresholds that
mobile uses are applied directly.
"""
from __future__ import annotations

import math

import numpy as np

from app.schemas.health_metrics import OxygenDesaturationTrendOut

# Mobile gate: 10 samples minimum. Below this, no meaningful baseline
# exists.
MIN_SPO2_SAMPLES = 10

# Mobile gate: 4 hours minimum. Below this, an overnight trend cannot be
# computed — one bad minute dominates the baseline.
MIN_WINDOW = np.timedelta64(4, "h") if hasattr(np, "timedelta64") else None
MIN_WINDOW_HOURS = 4.0


def _baseline_count(total_samples: int) -> int:
    """
    Mirrors mobile's baseline selection: first 10% of the window, minimum
    20 samples. A fixed first-100 baseline is fragile — one bad minute at
    the start of the night poisons the entire trend for that night.
    """
    return max(20, total_samples // 10)


def compute_desaturation_index(
    spo2_night: list[float],
    sampling_rate_hz: float = 1.0,
) -> float:
    """
    Engineering proxy count of SpO₂ dips per hour, relative to a moving
    baseline.

    NOT a clinical ODI. Mobile uses the same rule:

      - Event opens when value drops <= baseline - 3
      - Event closes when value recovers >= baseline - 2  (hysteresis)

    The earlier skip-10-samples hack could either count one long event as
    multiple or miss short events entirely. Hysteresis matches mobile and
    is what the training pipeline was calibrated against.
    """
    n = len(spo2_night)
    if n < MIN_SPO2_SAMPLES:
        return 0.0

    spo2 = np.asarray(spo2_night, dtype=np.float64)

    baseline_size = _baseline_count(n)
    baseline = float(np.mean(spo2[:baseline_size]))

    desaturation_events = 0
    inside_event = False

    for value in spo2:
        if value <= baseline - 3:
            if not inside_event:
                desaturation_events += 1
                inside_event = True
        elif value >= baseline - 2:
            inside_event = False

    hours = n / (sampling_rate_hz * 3600.0)
    if not math.isfinite(hours) or hours <= 0:
        return 0.0

    return desaturation_events / hours


def _insufficient_data(reason: str = "Collect more overnight SpO₂ data.") -> OxygenDesaturationTrendOut:
    return OxygenDesaturationTrendOut(
        desaturation_index_proxy=0.0,
        trend_score=0.0,
        trend_level="Insufficient data",
        recommendation=reason,
    )


def _recommendation_for(score: float) -> str:
    """
    Wellness-framed recommendations. Matches the copy in mobile's
    `computeOxygenDesaturationTrend`. Does not mention sleep apnea,
    apnea-hypopnea index, or a sleep study — none of which the hardware
    can support.
    """
    if score < 15:
        return (
            "No strong overnight oxygen trend was identified in this "
            "recording."
        )
    if score < 40:
        return (
            "A repeated overnight oxygen trend was observed. Continue "
            "monitoring. Discuss persistent patterns with a clinician."
        )
    return (
        "A repeated overnight oxygen trend was observed. Professional "
        "evaluation is appropriate if symptoms are present."
    )


def _rule_based(
    spo2_night: list[float],
    duration_hours: float | None = None,
) -> OxygenDesaturationTrendOut:
    """
    Mobile's algorithm, applied server-side.

    Thresholds match mobile exactly: <15 Low, <40 Medium, else High. The
    linear score scaling (index / 30 * 100) is identical.
    """
    if duration_hours is not None and duration_hours < MIN_WINDOW_HOURS:
        return _insufficient_data(
            "Collect at least several hours of overnight data."
        )

    index = compute_desaturation_index(spo2_night)
    trend_score = float(np.clip(index / 30.0 * 100.0, 0.0, 100.0))

    if trend_score < 15:
        level = "Low"
    elif trend_score < 40:
        level = "Medium"
    else:
        level = "High"

    return OxygenDesaturationTrendOut(
        desaturation_index_proxy=round(index, 1),
        trend_score=round(trend_score, 1),
        trend_level=level,
        recommendation=_recommendation_for(trend_score),
    )


def _ml_based(
    spo2_night: list[float],
    hr_night: list[float] | None,
    age: int,
    bmi: float,
    model,
    scaler,
    duration_hours: float | None = None,
) -> OxygenDesaturationTrendOut:
    """
    XGBoost path — feature engineering preserved from the training
    pipeline in `lib/python/sleep_apena.py`.

    The model returns a 3-class softmax; we use the High-risk class
    probability as the trend score.
    """
    if duration_hours is not None and duration_hours < MIN_WINDOW_HOURS:
        return _insufficient_data(
            "Collect at least several hours of overnight data."
        )

    index = compute_desaturation_index(spo2_night)
    mean_spo2 = float(np.mean(spo2_night))
    min_spo2 = float(np.min(spo2_night))
    time_below_90 = float(
        np.sum(np.asarray(spo2_night) < 90) / len(spo2_night) * 100
    )
    hr_std = float(np.std(hr_night)) if hr_night else 8.0

    features = np.array(
        [[index, mean_spo2, min_spo2, time_below_90, hr_std, age / 100, bmi / 40]]
    )
    features_scaled = scaler.transform(features)

    risk_proba = model.predict_proba(features_scaled)[0]
    risk_score = float(risk_proba[2] * 100)  # High-risk class probability * 100

    # Classify by the mobile thresholds, not the model's own argmax.
    # The model's argmax is a training-time artifact; the trend level
    # shown to the user must match what mobile would compute from the
    # same data.
    if risk_score < 15:
        level = "Low"
    elif risk_score < 40:
        level = "Medium"
    else:
        level = "High"

    return OxygenDesaturationTrendOut(
        desaturation_index_proxy=round(index, 1),
        trend_score=round(risk_score, 1),
        trend_level=level,
        recommendation=_recommendation_for(risk_score),
        class_probabilities=[round(float(p), 3) for p in risk_proba],
    )


def predict_sleep_apnea(
    spo2_night: list[float],
    hr_night: list[float] | None = None,
    age: int = 30,
    bmi: float = 24,
    model=None,
    scaler=None,
    duration_hours: float | None = None,
) -> OxygenDesaturationTrendOut:
    """Main entry point."""
    if len(spo2_night) < MIN_SPO2_SAMPLES:
        return _insufficient_data(
            "Collect more overnight SpO₂ data before computing a trend."
        )

    if model is None or scaler is None:
        return _rule_based(spo2_night, duration_hours)
    return _ml_based(
        spo2_night, hr_night, age, bmi, model, scaler, duration_hours
    )
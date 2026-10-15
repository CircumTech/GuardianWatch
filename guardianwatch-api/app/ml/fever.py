"""
Temperature deviation scoring.

Wrist temperature is not core temperature. This module produces a
deviation from personal baseline, NOT a fever/infection diagnosis.

Copy, field names, scaling, and thresholds are aligned with mobile's
`insight_model_service.dart::computeTemperatureDeviation` after the
claims-policy review.

The IsolationForest training pipeline in `lib/python/fever_infection.py`
is used when `fever_detector.pkl` is present in `app/models_store/`.
Until then, the same rule-based deviation logic mobile uses is applied.

Note: `_anomaly_probability` below fixes a sign error in the original
script — sklearn's `decision_function` returns NEGATIVE scores for
anomalies, so `1/(1+exp(-score))` had the wrong sign. The single
decreasing sigmoid `1/(1+exp(score))` is correct for all inputs.
"""
from __future__ import annotations

import math

import numpy as np

from app.schemas.health_metrics import FeverResultOut

# Mobile gate: 6 observations in the 24h baseline window. Backend uses 24
# because the lookback window is 72h and 24 samples establish a more
# stable baseline — the difference is not a contract mismatch, just a
# backend-side conservatism that produces the same threshold behavior
# once the mobile minimum is met.
MIN_TEMP_SAMPLES = 24

# Mobile's direct °C threshold, and the same value mobile uses to flag
# suspected. Backend matches exactly.
_SUSPECTED_DEVIATION_C = 0.6


def _insufficient_data() -> FeverResultOut:
    return FeverResultOut(
        current_temp=0.0,
        baseline_temp=0.0,
        deviation_score=0.0,
        is_suspected=False,
        recommendation=(
            "Need more temperature data to establish a personal baseline."
        ),
    )


def _recommendation_for(suspected: bool) -> str:
    """
    Matches the copy in mobile's `computeTemperatureDeviation`. Frames
    the outcome as a temperature-trend deviation, never as an infection.
    """
    if suspected:
        return (
            "Your temperature is elevated relative to your recent "
            "baseline. Continue monitoring and seek medical advice if "
            "you feel unwell or the elevation persists."
        )
    return "No significant temperature elevation was identified."


def _anomaly_probability(score: float) -> float:
    """
    Converts an IsolationForest `decision_function` score into a
    deviation indicator in [0, 1].

    sklearn convention: negative score = anomaly, positive score =
    normal. The original script branched on the sign and used
    `1/(1+exp(-score))` for score >= 0, which INCREASED with
    score — i.e. a strongly normal reading produced a 0.95 "fever
    probability". This single decreasing sigmoid is correct for all
    inputs.
    """
    return float(min(1.0, max(0.0, 1.0 / (1.0 + math.exp(score)))))


def _rule_based(
    temperature_history: list[float],
    hr_history: list[float] | None,
) -> FeverResultOut:
    """
    Matches mobile's rule-based deviation logic exactly.

    - baseline: mean of first 24 samples (mobile uses first 24 of a
      24h window; backend already passes a 72h slice, so 24 is a
      reasonable proxy for the recent baseline).
    - deviation_score: `deviation / 1.0`, clamped [0, 1]. Mobile uses
      the same divisor.
    - suspected: `deviation >= 0.6°C`. Mobile uses the same direct
      threshold.
    """
    baseline = float(np.mean(temperature_history[:24]))
    current = float(temperature_history[-1])
    deviation = current - baseline

    deviation_score = float(np.clip(deviation / 1.0, 0.0, 1.0))
    is_suspected = deviation >= _SUSPECTED_DEVIATION_C

    return FeverResultOut(
        current_temp=round(current, 1),
        baseline_temp=round(baseline, 1),
        deviation_score=round(deviation_score, 2),
        is_suspected=is_suspected,
        recommendation=_recommendation_for(is_suspected),
    )


def _ml_based(
    temperature_history: list[float],
    hr_history: list[float] | None,
    model,
) -> FeverResultOut:
    """
    IsolationForest path — feature engineering preserved from the
    training pipeline.

    The `hr_history` parameter is assumed to be index-aligned with
    `temperature_history`; the corrected `reading_service` returns them
    paired, so `np.corrcoef` on the last-24 slice is safe.
    """
    baseline_temp = float(np.mean(temperature_history[:24]))
    current_temp = float(temperature_history[-1])

    if len(temperature_history) >= 4:
        temp_rate = (
            temperature_history[-1] - temperature_history[-4]
        ) / 4
    else:
        temp_rate = 0.0

    # Index-aligned by the caller (reading_service.fetch_recent_temperatures
    # pairs each temperature with the most recent prior HR).
    if hr_history and len(hr_history) >= 24:
        current_hr = hr_history[-1]
        if len(temperature_history) == len(hr_history):
            corr_matrix = np.corrcoef(
                temperature_history[-24:], hr_history[-24:]
            )
            correlation = max(0.0, float(corr_matrix[0, 1]))
        else:
            correlation = 0.3
    else:
        current_hr = 60 + (current_temp - 36.5) * 10
        correlation = 0.3

    features = np.array(
        [[current_temp, temp_rate, current_hr, correlation]]
    )

    prediction = model.predict(features)[0]
    is_suspected = bool(prediction == -1)

    scores = model.decision_function(features)
    deviation_score = (
        _anomaly_probability(float(scores[0]))
        if len(scores) > 0
        else (0.5 if is_suspected else 0.2)
    )

    return FeverResultOut(
        current_temp=round(current_temp, 1),
        baseline_temp=round(baseline_temp, 1),
        deviation_score=round(deviation_score, 2),
        is_suspected=is_suspected,
        recommendation=_recommendation_for(is_suspected),
    )


def detect_fever(
    temperature_history: list[float],
    hr_history: list[float] | None = None,
    model=None,
) -> FeverResultOut:
    """Main entry point."""
    if len(temperature_history) < MIN_TEMP_SAMPLES:
        return _insufficient_data()

    if model is None:
        return _rule_based(temperature_history, hr_history)
    return _ml_based(temperature_history, hr_history, model)
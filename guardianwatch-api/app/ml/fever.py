"""
Fever / infection detection.

Ported from `lib/python/fever_infection.py` (IsolationForest anomaly
detection), with the deviation-threshold fallback from
`insight_model_service.dart::detectFever()` when the model isn't loaded.

One deliberate fix versus the original script: see `_anomaly_probability()`
below.
"""
from __future__ import annotations

import numpy as np

from app.schemas.health_metrics import FeverResultOut

MIN_TEMP_SAMPLES = 24


def _insufficient_data() -> FeverResultOut:
    return FeverResultOut(
        current_temp=0, baseline_temp=0, probability=0, is_suspected=False,
        recommendation="Need at least 24 hours of temperature data to establish a baseline.",
    )


def _anomaly_probability(score: float) -> float:
    """
    Converts an IsolationForest `decision_function` score into a
    fever-likelihood probability in [0, 1].

    The original script (`fever_infection.py::detect_fever`) branched on
    the sign of `score` and used `1/(1+exp(-score))` for score >= 0. That
    branch is backwards: sklearn's convention is negative-score = anomaly,
    positive-score = normal, so that formula makes probability INCREASE
    as a reading gets *more* normal (a score of +3, a strongly normal
    reading, worked out to 0.95 "fever probability"). The single formula
    used here, `1/(1+exp(score))`, is monotonically decreasing in score
    for all values and needs no branch — it's what the original's
    score < 0 branch already computed correctly.
    """
    probability = 1.0 / (1.0 + np.exp(score))
    return float(min(1.0, max(0.0, probability)))


def _rule_based(
    temperature_history: list[float],
    hr_history: list[float] | None,
) -> FeverResultOut:
    """Verbatim port of the fallback in `detectFever()` (insight_model_service.dart)."""
    baseline = float(np.mean(temperature_history[:24]))
    current = float(temperature_history[-1])
    deviation = current - baseline

    probability = float(np.clip(deviation / 0.5, 0, 1))
    is_suspected = probability > 0.6

    return FeverResultOut(
        current_temp=round(current, 1),
        baseline_temp=round(baseline, 1),
        probability=round(probability, 2),
        is_suspected=is_suspected,
        recommendation=(
            "Rest, hydrate, and monitor your temperature. Consult a doctor if it persists."
            if is_suspected else "Your temperature is within normal range."
        ),
    )


def _ml_based(
    temperature_history: list[float],
    hr_history: list[float] | None,
    model,
) -> FeverResultOut:
    """Ported from `detect_fever()` in fever_infection.py (feature engineering
    preserved exactly; only the probability post-processing was fixed)."""
    baseline_temp = float(np.mean(temperature_history[:24]))
    current_temp = float(temperature_history[-1])

    if len(temperature_history) >= 4:
        temp_rate = (temperature_history[-1] - temperature_history[-4]) / 4
    else:
        temp_rate = 0.0

    if hr_history and len(hr_history) >= 24:
        current_hr = hr_history[-1]
        if len(temperature_history) == len(hr_history):
            corr_matrix = np.corrcoef(temperature_history[-24:], hr_history[-24:])
            correlation = max(0.0, float(corr_matrix[0, 1]))
        else:
            correlation = 0.3
    else:
        current_hr = 60 + (current_temp - 36.5) * 10
        correlation = 0.3

    features = np.array([[current_temp, temp_rate, current_hr, correlation]])

    prediction = model.predict(features)[0]
    is_suspected = bool(prediction == -1)

    scores = model.decision_function(features)
    probability = _anomaly_probability(float(scores[0])) if len(scores) > 0 else (0.5 if is_suspected else 0.2)

    return FeverResultOut(
        current_temp=round(current_temp, 1),
        baseline_temp=round(baseline_temp, 1),
        probability=round(probability, 2),
        is_suspected=is_suspected,
        recommendation=(
            "Rest, hydrate, and monitor your temperature. Consult a doctor if it persists."
            if is_suspected else "Your temperature is within normal range."
        ),
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

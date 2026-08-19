"""
Sleep apnea risk scoring.

`sleep_apena.py` defines training + prediction for an XGBoost classifier,
but `sleep_apnea_model.pkl` / `sleep_apnea_scaler.pkl` were not included in
the uploaded project — only the training code was. This module still
implements the exact same feature engineering (`compute_odi` is a verbatim
port), so:

  - If you train the model (`python lib/python/sleep_apena.py`) and drop
    `sleep_apnea_model.pkl` + `sleep_apnea_scaler.pkl` into
    `app/models_store/`, `ModelRegistry` picks them up automatically on
    next boot — nothing in this file or its callers needs to change.
  - Until then, risk is scored with the same odi/risk_score thresholds
    `insight_model_service.dart::computeSleepApneaRisk()` already uses.
"""
from __future__ import annotations

import numpy as np

from app.schemas.health_metrics import SleepApneaRiskOut

MIN_SPO2_SAMPLES = 100  # matches compute_odi()'s own internal gate


def compute_odi(spo2_night: list[float], sampling_rate_hz: float = 1) -> float:
    """Verbatim port of `compute_odi()` in sleep_apena.py."""
    if len(spo2_night) < 100:
        return 0.0

    spo2 = np.asarray(spo2_night, dtype=np.float64)
    baseline = float(np.mean(spo2[: min(100, len(spo2))]))

    desaturations = 0
    i = 0
    while i < len(spo2):
        if spo2[i] < baseline - 3:
            desaturations += 1
            i += 10  # approximate skip past this desaturation event
        i += 1

    hours = len(spo2) / (sampling_rate_hz * 3600)
    return desaturations / max(hours, 1)


def _insufficient_data() -> SleepApneaRiskOut:
    return SleepApneaRiskOut(
        odi=0, risk_score=0, risk_level="Insufficient data",
        recommendation="Wear your watch while sleeping to get sleep apnea analysis.",
    )


def _rule_based(spo2_night: list[float]) -> SleepApneaRiskOut:
    """
    Same odi → risk_score → risk_level mapping as
    `computeSleepApneaRisk()` in insight_model_service.dart (0-100 score,
    <15 low / <40 medium / else high) — the tested, currently-shipping
    thresholds, applied here to the more principled `compute_odi()`
    desaturation-skip logic from the Python reference script.
    """
    odi = compute_odi(spo2_night)
    risk_score = float(np.clip(odi / 30 * 100, 0, 100))

    if risk_score < 15:
        risk_level, recommendation = "Low", "Your sleep breathing appears normal."
    elif risk_score < 40:
        risk_level, recommendation = "Medium", "Consider sleeping on your side and maintaining a healthy weight."
    else:
        risk_level, recommendation = "High", "Consult a doctor about a sleep study."

    return SleepApneaRiskOut(
        odi=round(odi, 1), risk_score=round(risk_score, 1),
        risk_level=risk_level, recommendation=recommendation,
    )


def _ml_based(
    spo2_night: list[float],
    hr_night: list[float] | None,
    age: int,
    bmi: float,
    model,
    scaler,
) -> SleepApneaRiskOut:
    """Verbatim port of `predict_sleep_apnea()` in sleep_apena.py."""
    odi = compute_odi(spo2_night)
    mean_spo2 = float(np.mean(spo2_night))
    min_spo2 = float(np.min(spo2_night))
    time_below_90 = float(np.sum(np.asarray(spo2_night) < 90) / len(spo2_night) * 100)

    hr_std = float(np.std(hr_night)) if hr_night else 8.0

    features = np.array([[odi, mean_spo2, min_spo2, time_below_90, hr_std, age / 100, bmi / 40]])
    features_scaled = scaler.transform(features)

    risk_proba = model.predict_proba(features_scaled)[0]
    risk_class = int(np.argmax(risk_proba))
    risk_score = float(risk_proba[2] * 100)  # High-risk class probability * 100

    if risk_class == 0:
        risk_level, recommendation = "Low", "Your sleep breathing appears normal."
    elif risk_class == 1:
        risk_level, recommendation = "Medium", "Consider sleeping on your side and maintaining a healthy weight."
    else:
        risk_level, recommendation = "High", "Consult a doctor about a sleep study."

    return SleepApneaRiskOut(
        odi=round(odi, 1), risk_score=round(risk_score, 1),
        risk_level=risk_level, recommendation=recommendation,
        class_probabilities=[round(float(p), 3) for p in risk_proba],
    )


def predict_sleep_apnea(
    spo2_night: list[float],
    hr_night: list[float] | None = None,
    age: int = 30,
    bmi: float = 24,
    model=None,
    scaler=None,
) -> SleepApneaRiskOut:
    """Main entry point."""
    if len(spo2_night) < MIN_SPO2_SAMPLES:
        return _insufficient_data()

    if model is None or scaler is None:
        return _rule_based(spo2_night)
    return _ml_based(spo2_night, hr_night, age, bmi, model, scaler)

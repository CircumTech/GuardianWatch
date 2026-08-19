"""
HRV & stress scoring.

Ported from `lib/python/hrv_stress_score.py` (feature extraction +
RandomForestRegressor) with the rule-based path from
`insight_model_service.dart::computeHRV()` as the fallback when
`stress_model.pkl` isn't loaded. Both paths share the same "insufficient
data" threshold (30 RR intervals) that the Dart app already uses.
"""
from __future__ import annotations

import numpy as np
from scipy import signal as scipy_signal

from app.schemas.health_metrics import HRVMetricsOut

MIN_RR_INTERVALS = 30


def compute_hrv_features(rr_intervals: list[float]) -> dict:
    """Verbatim port of `compute_hrv_features()` in hrv_stress_score.py."""
    rr = np.asarray(rr_intervals, dtype=np.float64)
    diff_rr = np.diff(rr)

    features = {
        "mean_rr": float(np.mean(rr)),
        "sdnn": float(np.std(rr)),
        "rmssd": float(np.sqrt(np.mean(diff_rr ** 2))) if len(diff_rr) else 0.0,
        "pnn50": float(np.sum(np.abs(diff_rr) > 50) / len(diff_rr) * 100) if len(diff_rr) > 0 else 0.0,
        "lf_power": 0.0,
        "hf_power": 0.0,
        "lf_hf_ratio": 0.0,
    }

    if len(rr) > 30:
        try:
            t = np.cumsum(rr) / 1000.0
            if len(t) > 1:
                t_uniform = np.linspace(t[0], t[-1], len(rr))
                rr_uniform = np.interp(t_uniform, t, rr)
                rr_detrended = rr_uniform - np.mean(rr_uniform)

                freqs = np.linspace(0.003, 0.4, 500)
                periodogram = scipy_signal.lombscargle(
                    t_uniform, rr_detrended, 2 * np.pi * freqs
                )
                periodogram = np.sqrt(periodogram / len(t_uniform))

                lf_mask = (freqs >= 0.04) & (freqs < 0.15)
                hf_mask = (freqs >= 0.15) & (freqs < 0.4)

                features["lf_power"] = float(np.sum(periodogram[lf_mask]))
                features["hf_power"] = float(np.sum(periodogram[hf_mask]))
                features["lf_hf_ratio"] = features["lf_power"] / (features["hf_power"] + 1e-6)
        except Exception:
            pass  # frequency-domain features stay at 0 — matches the reference script

    return features


def _insufficient_data() -> HRVMetricsOut:
    """Matches `computeHRV()`'s early-return in insight_model_service.dart exactly."""
    return HRVMetricsOut(
        rmssd=0, sdnn=0, stress_score=50,
        stress_level="Insufficient data", recovery_status="Need more ECG data",
    )


def _rule_based(rr_intervals: list[float]) -> HRVMetricsOut:
    """
    Same math as the Dart on-device fallback (used today for every user,
    since the app never had a trained model on-device for this metric).
    """
    rr = np.asarray(rr_intervals, dtype=np.float64)
    diffs = np.abs(np.diff(rr))
    rmssd = float(np.sqrt(np.mean(diffs ** 2)))
    sdnn = float(np.std(rr))

    stress_score = float(np.clip(100 - (rmssd / 80 * 100), 0, 100))
    stress_level = "Low" if stress_score < 30 else "Medium" if stress_score < 60 else "High"

    if rmssd > 50:
        recovery_status = "Excellent recovery"
    elif rmssd > 35:
        recovery_status = "Good recovery"
    elif rmssd > 25:
        recovery_status = "Normal recovery"
    else:
        recovery_status = "Poor recovery"

    return HRVMetricsOut(
        rmssd=round(rmssd), sdnn=round(sdnn), stress_score=round(stress_score),
        stress_level=stress_level, recovery_status=recovery_status,
    )


def predict_stress(rr_intervals: list[float], model=None) -> HRVMetricsOut:
    """
    Main entry point. Prefers the trained RandomForestRegressor
    (`stress_model.pkl`) when available — a genuine upgrade over the
    on-device rule, which was only ever a simple RMSSD threshold. Falls
    back to that same rule when the model isn't loaded.
    """
    if len(rr_intervals) < MIN_RR_INTERVALS:
        return _insufficient_data()

    if model is None:
        return _rule_based(rr_intervals)

    features = compute_hrv_features(rr_intervals)
    feature_vector = np.array([[features["rmssd"], features["sdnn"], features["lf_hf_ratio"]]])
    stress_score = float(model.predict(feature_vector)[0])
    stress_score = max(0.0, min(100.0, stress_score))

    if stress_score < 30:
        stress_level, recovery_status = "Low", "Excellent recovery"
    elif stress_score < 60:
        stress_level, recovery_status = "Medium", "Normal recovery"
    else:
        stress_level, recovery_status = "High", "Poor recovery"

    return HRVMetricsOut(
        rmssd=round(features["rmssd"], 1),
        sdnn=round(features["sdnn"], 1),
        stress_score=round(stress_score, 1),
        stress_level=stress_level,
        recovery_status=recovery_status,
    )

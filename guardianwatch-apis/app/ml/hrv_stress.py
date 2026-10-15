"""
HRV & stress scoring.

Aligned with mobile's `insight_model_service.dart::computeHRV` after the
claims-policy review. The rule-based path uses identical math, identical
recovery-status thresholds, and identical copy. The ML path (RandomForest
on `[rmssd, sdnn, lf_hf_ratio]`) produces a different `stress_score`
value than the mobile rule, but the derived `recovery_status` and
`stress_level` fields use the same rules mobile uses — so the user sees
consistent framing regardless of which path produced the number.
"""
from __future__ import annotations

import numpy as np
from scipy import signal as scipy_signal

from app.schemas.health_metrics import HRVMetricsOut

MIN_RR_INTERVALS = 30

# Mobile filters RR intervals to this range before computing HRV, to
# exclude ectopic beats and detector artifacts. The filter is applied in
# `insight_service._rr_intervals_from_readings` upstream, but we apply it
# again here as a defensive measure — the thresholds are cheap and the
# signal they exclude is clearly non-physiological.
_MIN_RR_MS = 300
_MAX_RR_MS = 2000


def _filter_rr(rr_intervals: list[float]) -> np.ndarray:
    rr = np.asarray(rr_intervals, dtype=np.float64)
    return rr[(rr >= _MIN_RR_MS) & (rr <= _MAX_RR_MS)]


def compute_hrv_features(rr_intervals: list[float]) -> dict:
    """Verbatim port of `compute_hrv_features()` in hrv_stress_score.py."""
    rr = np.asarray(rr_intervals, dtype=np.float64)
    diff_rr = np.diff(rr)

    features = {
        "mean_rr": float(np.mean(rr)) if len(rr) else 0.0,
        "sdnn": float(np.std(rr)) if len(rr) else 0.0,
        "rmssd": (
            float(np.sqrt(np.mean(diff_rr ** 2))) if len(diff_rr) else 0.0
        ),
        "pnn50": (
            float(np.sum(np.abs(diff_rr) > 50) / len(diff_rr) * 100)
            if len(diff_rr) > 0
            else 0.0
        ),
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
                features["lf_hf_ratio"] = features["lf_power"] / (
                    features["hf_power"] + 1e-6
                )
        except Exception:
            # Frequency-domain features stay at 0 — matches the
            # reference script's own defensive behavior.
            pass

    return features


def _insufficient_data() -> HRVMetricsOut:
    """Byte-for-byte match with mobile's `_insufficientHrv()`."""
    return HRVMetricsOut(
        rmssd=0.0,
        sdnn=0.0,
        stress_score=50.0,
        stress_level="Insufficient data",
        recovery_status="Need more clean ECG data",
    )


def _recovery_status_from_rmssd(rmssd: float) -> str:
    """
    Mobile's exact thresholds. Recovery status is an HRV-derived concept
    — it must be computed from rmssd, not from the model's stress score.
    """
    if rmssd > 50:
        return "Excellent recovery"
    if rmssd > 35:
        return "Good recovery"
    if rmssd > 25:
        return "Normal recovery"
    return "Poor recovery"


def _stress_level_from_score(score: float) -> str:
    """Mobile's exact thresholds."""
    if score < 30:
        return "Low"
    if score < 60:
        return "Medium"
    return "High"


def _rule_based(rr_intervals: list[float]) -> HRVMetricsOut:
    """
    Byte-for-byte match with mobile's rule-based HRV.

    Numbers are returned unrounded — mobile does not round them either,
    and the mobile UI displays them via `toStringAsFixed(...)` at render
    time. Rounding here would produce values that differ from what the
    on-device path shows for the same RR series.
    """
    rr = _filter_rr(rr_intervals)
    if len(rr) < MIN_RR_INTERVALS:
        return _insufficient_data()

    diff_rr = np.diff(rr)
    rmssd = float(np.sqrt(np.mean(diff_rr ** 2)))
    sdnn = float(np.std(rr))

    stress_score = float(np.clip(100 - (rmssd / 80 * 100), 0, 100))

    return HRVMetricsOut(
        rmssd=rmssd,
        sdnn=sdnn,
        stress_score=stress_score,
        stress_level=_stress_level_from_score(stress_score),
        recovery_status=_recovery_status_from_rmssd(rmssd),
    )


def predict_stress(rr_intervals: list[float], model=None) -> HRVMetricsOut:
    """
    Main entry point.

    Prefers the trained RandomForestRegressor when available; falls back
    to the same rule the mobile app uses when the model isn't loaded.

    Both paths return values that round the same way (or don't round at
    all), so the insight-service copy produces identical text on the two
    surfaces.
    """
    rr = _filter_rr(rr_intervals)
    if len(rr) < MIN_RR_INTERVALS:
        return _insufficient_data()

    if model is None:
        return _rule_based(rr_intervals)

    features = compute_hrv_features(rr.tolist())
    feature_vector = np.array(
        [[features["rmssd"], features["sdnn"], features["lf_hf_ratio"]]]
    )
    stress_score = float(model.predict(feature_vector)[0])
    stress_score = float(np.clip(stress_score, 0.0, 100.0))

    return HRVMetricsOut(
        rmssd=features["rmssd"],
        sdnn=features["sdnn"],
        stress_score=stress_score,
        stress_level=_stress_level_from_score(stress_score),
        # Recovery status is derived from rmssd, NOT from stress_score.
        # Mobile does the same, and the two metrics measure different
        # things — stress_score is an aggregate indicator, rmssd is
        # parasympathetic activity specifically.
        recovery_status=_recovery_status_from_rmssd(features["rmssd"]),
    )
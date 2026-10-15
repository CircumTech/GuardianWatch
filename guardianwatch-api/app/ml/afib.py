"""
Atrial fibrillation / rhythm irregularity detection.

The output is an ENGINEERING IRREGULARITY INDICATOR, not a probability
of AFib. The field is deliberately named to match the mobile app's
`AFibResult.irregularityIndicator` so neither surface implies a
diagnosis. See the report's Phase 1 / Phase 2 / Phase 3 claims policy.

Two independent paths, same as the Flutter app's design:
  - ML path: the 1D CNN (`afib_detection.tflite`)
  - Rule-based path: R-peak coefficient-of-variation heuristic
"""
from __future__ import annotations

import math

import numpy as np

from app.schemas.health_metrics import AFibResultOut

# 4 seconds at 250 Hz — matches the mobile `_minimumAfibSamples` in
# insight_model_service.dart. Shorter windows produce unstable RR
# series and should not be scored.
MIN_SAMPLES_FOR_ML = 1000

# Decision threshold for the model's output. Locked to the value used
# during model validation. Applied to `irregularity_indicator` (0–1).
_DECISION_THRESHOLD = 0.70


def preprocess_ecg_segment(
    ecg_segment: list[float], target_length: int = 2500
) -> np.ndarray:
    """
    Resample to the model's training window and per-window z-score
    normalize. Matches `_zScoreNormalize` in insight_model_service.dart
    and `preprocess_ecg_segment()` in the training script.
    """
    ecg = np.asarray(ecg_segment, dtype=np.float64)
    if len(ecg) != target_length:
        x_old = np.linspace(0, 1, len(ecg))
        x_new = np.linspace(0, 1, target_length)
        ecg = np.interp(x_new, x_old, ecg)
    mean = float(np.mean(ecg))
    std = float(np.std(ecg))
    if std < 1e-6:
        return np.zeros(target_length, dtype=np.float64)
    return (ecg - mean) / std


def _moving_average_detrend(
    signal: np.ndarray, window: int = 5
) -> np.ndarray:
    """
    Prefix-sum sliding window detrend — O(n). Matches
    `_movingAverageDetrend` in insight_model_service.dart after our fix.
    """
    n = len(signal)
    if n == 0:
        return signal

    prefix = np.zeros(n + 1, dtype=np.float64)
    for i in range(n):
        prefix[i + 1] = prefix[i] + signal[i]

    half = window // 2
    out = np.zeros(n, dtype=np.float64)
    for i in range(n):
        start = max(0, i - half)
        end = min(n - 1, i + half)
        count = end - start + 1
        baseline = (prefix[end + 1] - prefix[start]) / count if count else 0.0
        out[i] = signal[i] - baseline
    return out


def detect_r_peaks(ecg_segment: list[float]) -> list[int]:
    """
    Adaptive-threshold R-peak detector.

    Matches `_detectRPeaks` in insight_model_service.dart after the
    claims-policy review — detrended signal, adaptive threshold based on
    observed amplitude range, minimum peak distance. The earlier
    `max * 0.6` fixed threshold on the raw signal was measurably
    different from mobile and produced different RR series for the same
    input.
    """
    if not ecg_segment:
        return []

    signal = np.asarray(ecg_segment, dtype=np.float64)
    if len(signal) < 5:
        return []

    filtered = _moving_average_detrend(signal, window=5)
    amplitude_range = float(np.max(filtered) - np.min(filtered))
    if not math.isfinite(amplitude_range) or amplitude_range <= 0:
        return []

    threshold = float(np.min(filtered)) + amplitude_range * 0.65

    # 40 samples at 250 Hz ≈ 160 BPM — same guard as mobile.
    minimum_peak_distance = 40

    peaks: list[int] = []
    last_accepted = None

    for i in range(1, len(filtered) - 1):
        current = filtered[i]
        if current < threshold:
            continue
        is_local_max = current > filtered[i - 1] and current >= filtered[i + 1]
        if not is_local_max:
            continue

        if last_accepted is not None and i - last_accepted < minimum_peak_distance:
            if peaks and current > filtered[peaks[-1]]:
                peaks[-1] = i
                last_accepted = i
            continue

        peaks.append(i)
        last_accepted = i

    return peaks


def _rule_based(ecg_segment: list[float]) -> AFibResultOut:
    """Coefficient-of-variation heuristic on RR intervals."""
    peaks = detect_r_peaks(ecg_segment)
    if len(peaks) < 5:
        return AFibResultOut(
            irregularity_indicator=0.0,
            is_suspected=False,
            confidence="Insufficient data",
        )

    # RR intervals in sample units, converted to ms at 250 Hz.
    rr_ms: list[float] = []
    for i in range(1, len(peaks)):
        sample_diff = peaks[i] - peaks[i - 1]
        if sample_diff <= 0:
            continue
        rr = sample_diff / 250.0 * 1000.0
        if 300 <= rr <= 2000:
            rr_ms.append(rr)

    if len(rr_ms) < 4:
        return AFibResultOut(
            irregularity_indicator=0.0,
            is_suspected=False,
            confidence="Low",
        )

    arr = np.asarray(rr_ms, dtype=np.float64)
    mean = float(np.mean(arr))
    if not math.isfinite(mean) or mean <= 0:
        return AFibResultOut(
            irregularity_indicator=0.0,
            is_suspected=False,
            confidence="Low",
        )

    cv = float(np.std(arr) / mean)
    indicator = float(np.clip((cv - 0.10) / 0.30, 0.0, 1.0))

    return AFibResultOut(
        irregularity_indicator=round(indicator, 3),
        is_suspected=indicator >= _DECISION_THRESHOLD,
        confidence="Low",
    )


def _ml_based(ecg_segment: list[float], registry) -> AFibResultOut:
    processed = preprocess_ecg_segment(ecg_segment)
    input_tensor = processed.reshape(1, -1, 1).astype(np.float32)

    interpreter = registry.afib_interpreter
    interpreter.set_tensor(registry.afib_input_index, input_tensor)
    interpreter.invoke()
    output = interpreter.get_tensor(registry.afib_output_index)

    score = float(output[0][0])
    score = max(0.0, min(1.0, score))

    if score >= 0.80:
        confidence = "High"
    elif score >= 0.60:
        confidence = "Medium"
    else:
        confidence = "Low"

    return AFibResultOut(
        irregularity_indicator=round(score, 3),
        is_suspected=score >= _DECISION_THRESHOLD,
        confidence=confidence,
    )


def predict_afib(ecg_segment: list[float], registry) -> AFibResultOut:
    """Main entry point — dispatches to ML or rule-based path."""
    if not ecg_segment or len(ecg_segment) < MIN_SAMPLES_FOR_ML:
        return _rule_based(ecg_segment) if ecg_segment else AFibResultOut(
            irregularity_indicator=0.0,
            is_suspected=False,
            confidence="Insufficient data",
        )

    if registry.afib_interpreter is not None:
        try:
            return _ml_based(ecg_segment, registry)
        except Exception:
            return _rule_based(ecg_segment)

    return _rule_based(ecg_segment)
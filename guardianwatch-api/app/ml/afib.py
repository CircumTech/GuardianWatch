"""
Atrial fibrillation detection.

Two independent paths, same as the Flutter app's own design:
  - ML path: the 1D CNN (`afib_detection.tflite`), ported from
    `afib_detection.py`'s `preprocess_ecg_segment` + `predict_afib`.
  - Rule-based path: R-peak coefficient-of-variation heuristic, ported
    verbatim from `insight_model_service.dart::detectAFib()`.

The ML path is preferred whenever the interpreter loaded successfully and
the segment carries enough samples to be a meaningful resample target;
otherwise this falls back to the rule-based path, exactly mirroring the
app's own on-device graceful degradation.
"""
from __future__ import annotations

import numpy as np

from app.schemas.health_metrics import AFibResultOut

MIN_SAMPLES_FOR_ML = 250  # ~1s of signal at a typical 250Hz wearable ECG rate


def preprocess_ecg_segment(ecg_segment: list[float], target_length: int = 2500) -> np.ndarray:
    """Verbatim port of `preprocess_ecg_segment()` in afib_detection.py."""
    ecg = np.asarray(ecg_segment, dtype=np.float64)
    if len(ecg) != target_length:
        x_old = np.linspace(0, 1, len(ecg))
        x_new = np.linspace(0, 1, target_length)
        ecg = np.interp(x_new, x_old, ecg)
    ecg = ecg - np.mean(ecg)
    ecg = ecg / (np.std(ecg) + 1e-6)
    return ecg


def detect_r_peaks(ecg_segment: list[float]) -> list[int]:
    """Verbatim port of `_detectRPeaks()` in insight_model_service.dart."""
    if not ecg_segment:
        return []
    signal = np.asarray(ecg_segment, dtype=np.float64)
    threshold = float(np.max(signal)) * 0.6
    peaks = []
    for i in range(1, len(signal) - 1):
        if signal[i] > threshold and signal[i] > signal[i - 1] and signal[i] > signal[i + 1]:
            peaks.append(i)
    return peaks


def _rule_based(ecg_segment: list[float]) -> AFibResultOut:
    """Verbatim port of the CV-based fallback in `detectAFib()`."""
    peaks = detect_r_peaks(ecg_segment)
    rr_diffs = [peaks[i] - peaks[i - 1] for i in range(1, len(peaks))]

    if not rr_diffs:
        return AFibResultOut(probability=0, is_suspected=False, confidence="Low")

    rr = np.asarray(rr_diffs, dtype=np.float64)
    mean = float(np.mean(rr))
    cv = float(np.std(rr) / mean) if mean else 0.0

    probability = float(np.clip((cv - 0.15) / 0.2, 0, 1))
    return AFibResultOut(
        probability=round(probability, 3),
        is_suspected=probability > 0.5,
        confidence="Medium" if probability > 0.7 else "Low",
    )


def _ml_based(ecg_segment: list[float], registry) -> AFibResultOut:
    processed = preprocess_ecg_segment(ecg_segment)
    input_tensor = processed.reshape(1, -1, 1).astype(np.float32)

    interpreter = registry.afib_interpreter
    interpreter.set_tensor(registry.afib_input_index, input_tensor)
    interpreter.invoke()
    output = interpreter.get_tensor(registry.afib_output_index)
    probability = float(output[0][0])

    if probability > 0.8:
        confidence = "High"
    elif probability > 0.6:
        confidence = "Medium"
    else:
        confidence = "Low"

    return AFibResultOut(
        probability=round(probability, 3),
        is_suspected=probability > 0.5,
        confidence=confidence,
    )


def predict_afib(ecg_segment: list[float], registry) -> AFibResultOut:
    """Main entry point — dispatches to ML or rule-based path."""
    if registry.afib_interpreter is not None and len(ecg_segment) >= MIN_SAMPLES_FOR_ML:
        try:
            return _ml_based(ecg_segment, registry)
        except Exception:
            # Never let a bad tensor shape / runtime hiccup take down an
            # insight request — degrade to the rule-based path instead.
            return _rule_based(ecg_segment)
    return _rule_based(ecg_segment)

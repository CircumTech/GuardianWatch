import math

import pytest

from app.ml.afib import detect_r_peaks, predict_afib, preprocess_ecg_segment


class _FakeRegistry:
    """A registry with no loaded AFib interpreter — forces the rule-based path."""
    afib_interpreter = None


def test_empty_segment_returns_no_signal():
    result = predict_afib([], _FakeRegistry())
    assert result.probability == 0
    assert result.is_suspected is False
    assert result.confidence == "Low"


def test_detect_r_peaks_finds_local_maxima_above_threshold():
    # Three clean spikes well above 60% of the signal's max.
    signal = [0, 0, 5, 0, 0, 0, 5, 0, 0, 0, 5, 0, 0]
    peaks = detect_r_peaks(signal)
    assert peaks == [2, 6, 10]


def test_regular_rhythm_low_afib_probability():
    # Perfectly regular spacing between peaks → coefficient of variation ~0
    # → rule-based probability should be at/near 0.
    signal = [0] * 200
    for i in range(20, 200, 30):
        signal[i] = 5
    result = predict_afib(signal, _FakeRegistry())
    assert result.probability < 0.2
    assert result.is_suspected is False


def test_irregular_rhythm_higher_afib_probability():
    # Deliberately irregular spacing → higher coefficient of variation.
    signal = [0] * 300
    positions = [10, 25, 65, 80, 150, 155, 220, 260]
    for p in positions:
        signal[p] = 5
    result = predict_afib(signal, _FakeRegistry())
    assert result.probability > 0


def test_preprocess_ecg_segment_normalizes_length_and_scale():
    raw = [1.0, 2.0, 3.0, 4.0, 5.0]
    processed = preprocess_ecg_segment(raw, target_length=100)
    assert len(processed) == 100
    assert abs(float(processed.mean())) < 1e-6  # zero-mean
    assert not math.isnan(float(processed.std()))


def test_ml_path_used_when_interpreter_available():
    """End-to-end through the real tflite model, if it loaded (skips
    cleanly if the model file isn't present in this environment)."""
    from app.ml.model_registry import build_model_registry

    registry = build_model_registry()
    if registry.afib_interpreter is None:
        pytest.skip("AFib tflite model not available in this environment")

    import numpy as np
    signal = (np.sin(np.linspace(0, 40 * np.pi, 2500)) + 0.02 * np.random.randn(2500)).tolist()
    result = predict_afib(signal, registry)
    assert 0 <= result.probability <= 1
    assert result.confidence in ("Low", "Medium", "High")

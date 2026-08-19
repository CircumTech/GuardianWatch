import joblib
import numpy as np
import pytest

from app.config import get_settings
from app.ml.fever import MIN_TEMP_SAMPLES, _anomaly_probability, detect_fever

settings = get_settings()


def test_insufficient_data_below_threshold():
    result = detect_fever(temperature_history=[36.5] * 10, hr_history=None, model=None)
    assert result.is_suspected is False
    assert "24 hours" in result.recommendation


def test_rule_based_no_fever_when_stable():
    temps = [36.5] * 30
    result = detect_fever(temps, hr_history=None, model=None)
    assert result.is_suspected is False
    assert result.probability == 0


def test_rule_based_fever_when_elevated():
    temps = [36.5] * 24 + [38.0]  # 1.5°C above baseline
    result = detect_fever(temps, hr_history=None, model=None)
    assert result.is_suspected is True
    assert result.probability == 1.0  # deviation/0.5 clamped to 1


def test_anomaly_probability_is_monotonically_decreasing():
    """
    Regression test for the sign-inversion bug in the original
    fever_infection.py script: a strongly *normal* IsolationForest score
    must map to a LOW fever probability, not a high one. See ml/fever.py
    docstring for the full explanation.
    """
    scores = [-3, -1, -0.1, 0, 0.1, 1, 3]
    probs = [_anomaly_probability(s) for s in scores]
    # Strictly decreasing as score increases (more "normal" → lower probability).
    assert all(probs[i] > probs[i + 1] for i in range(len(probs) - 1))
    # A strongly normal score should not read as a high fever probability.
    assert _anomaly_probability(3) < 0.1
    # A strongly anomalous score should read as a high fever probability.
    assert _anomaly_probability(-3) > 0.9


def test_trained_model_end_to_end():
    model = joblib.load(settings.MODEL_DIR / "fever_detector.pkl")
    temps = [36.5 + 0.05 * np.sin(i) for i in range(30)]
    result = detect_fever(temps, hr_history=[65] * 30, model=model)
    assert 0 <= result.probability <= 1
    assert isinstance(result.is_suspected, bool)

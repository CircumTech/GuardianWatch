import joblib
import numpy as np

from app.config import get_settings
from app.ml.fever import _anomaly_probability, detect_fever

settings = get_settings()


def test_insufficient_data_below_threshold():
    result = detect_fever(temperature_history=[36.5] * 10, hr_history=None, model=None)
    assert result.is_suspected is False
    # Copy was reframed to avoid claiming a specific window length.
    assert "baseline" in result.recommendation


def test_rule_based_no_fever_when_stable():
    temps = [36.5] * 30
    result = detect_fever(temps, hr_history=None, model=None)
    assert result.is_suspected is False
    # Field renamed from `probability` to `deviation_score`.
    assert result.deviation_score == 0


def test_rule_based_deviation_when_elevated():
    # 1.5 °C above baseline. The rule-based path scales deviation by
    # 1.0 (not 0.5 as in the earlier code), so 1.5 clamps to 1.0.
    temps = [36.5] * 24 + [38.0]
    result = detect_fever(temps, hr_history=None, model=None)
    assert result.is_suspected is True
    assert result.deviation_score == 1.0


def test_anomaly_probability_is_monotonically_decreasing():
    """
    Regression test for the sign-inversion bug in the original
    fever_infection.py script: a strongly NORMAL IsolationForest score
    must map to a LOW deviation indicator, not a high one.
    """
    scores = [-3, -1, -0.1, 0, 0.1, 1, 3]
    probs = [_anomaly_probability(s) for s in scores]
    assert all(probs[i] > probs[i + 1] for i in range(len(probs) - 1))
    assert _anomaly_probability(3) < 0.1
    assert _anomaly_probability(-3) > 0.9


def test_trained_model_end_to_end():
    model = joblib.load(settings.MODEL_DIR / "fever_detector.pkl")
    temps = [36.5 + 0.05 * np.sin(i) for i in range(30)]
    result = detect_fever(temps, hr_history=[65] * 30, model=model)
    assert 0 <= result.deviation_score <= 1
    assert isinstance(result.is_suspected, bool)
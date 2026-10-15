import joblib
import pytest

from app.config import get_settings
from app.ml.hrv_stress import MIN_RR_INTERVALS, predict_stress

settings = get_settings()


def test_insufficient_data_below_threshold():
    result = predict_stress(rr_intervals=[800, 810, 790], model=None)
    assert result.stress_level == "Insufficient data"
    assert result.stress_score == 50


def test_rule_based_low_stress_high_variability():
    # High RR variability (real HRV) → low stress under the rule-based formula.
    rr = [800, 850, 780, 900, 760, 870, 790, 910, 770, 860] * 3  # 30 samples
    result = predict_stress(rr, model=None)
    assert result.stress_level in ("Low", "Medium")
    assert 0 <= result.stress_score <= 100
    assert result.rmssd > 0


def test_rule_based_high_stress_low_variability():
    # Nearly-constant RR intervals (low HRV) → high stress under the rule-based formula.
    rr = [800] * 35
    result = predict_stress(rr, model=None)
    assert result.stress_score >= 95
    assert result.stress_level == "High"


def test_trained_model_produces_bounded_score():
    model = joblib.load(settings.MODEL_DIR / "stress_model.pkl")
    rr = [800, 820, 790, 830, 780, 810, 795, 805, 815, 825] * 3
    result = predict_stress(rr, model=model)
    assert 0 <= result.stress_score <= 100
    assert result.stress_level in ("Low", "Medium", "High")
    assert result.rmssd >= 0 and result.sdnn >= 0


@pytest.mark.parametrize("n", [0, 5, 29])
def test_insufficient_data_boundary(n):
    rr = [800] * n
    result = predict_stress(rr, model=None)
    assert n < MIN_RR_INTERVALS
    assert result.stress_level == "Insufficient data"

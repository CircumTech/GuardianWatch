import joblib

from app.config import get_settings
from app.ml.fatigue import MIN_RESTING_HR_DAYS, compute_fatigue

settings = get_settings()


def test_insufficient_data_below_threshold():
    result = compute_fatigue(resting_hr_trend=[58, 59], model=None)
    assert result.readiness == "Need more data"
    assert result.fatigue_score == 0


def test_rule_based_low_fatigue_stable_hr():
    hr = [58, 57, 59, 58, 57, 58, 57]  # stable, well-rested
    result = compute_fatigue(hr, sleep_hours=8, model=None)
    assert result.fatigue_score < 30
    assert "Ready" in result.readiness


def test_rule_based_high_fatigue_rising_hr_and_poor_sleep():
    hr = [58, 60, 63, 66, 69, 72, 75]  # clearly rising trend
    result = compute_fatigue(hr, sleep_hours=4, model=None)
    assert result.fatigue_score > 60
    assert "Rest day" in result.readiness


def test_boundary_exactly_seven_days_is_sufficient():
    hr = [60] * MIN_RESTING_HR_DAYS
    result = compute_fatigue(hr, model=None)
    assert result.readiness != "Need more data"


def test_trained_model_end_to_end():
    model = joblib.load(settings.MODEL_DIR / "fatigue_model.pkl")
    hr = [58, 57, 59, 58, 56, 57, 56, 58, 57, 59]
    result = compute_fatigue(hr, hr_recovery=25, sleep_hours=7.5, model=model)
    assert 0 <= result.fatigue_score <= 100
    assert result.readiness  # non-empty string

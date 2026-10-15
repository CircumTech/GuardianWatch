from app.ml.oxygen_trend import (
    MIN_SPO2_SAMPLES,
    compute_desaturation_index,
    compute_oxygen_trend,
)

def test_insufficient_data_below_threshold():
    result = compute_oxygen_trend(spo2_night=[96] * 5)
    # Class and field renamed for the claims policy: this is an oxygen
    # trend, not an apnea risk.
    assert result.trend_level == "Insufficient data"


def test_compute_index_stable_spo2_is_zero():
    spo2 = [96] * 200
    assert compute_desaturation_index(spo2) == 0


def test_compute_index_detects_desaturations():
    spo2 = [96] * 500
    # Inject clear desaturations (>3 points below baseline of ~96).
    for i in range(50, 450, 80):
        spo2[i] = 90
    index = compute_desaturation_index(spo2)
    assert index > 0


def test_rule_based_low_trend_stable_spo2():
    result = predict_sleep_apnea(spo2_night=[96] * MIN_SPO2_SAMPLES)
    assert result.trend_level == "Low"
    assert result.trend_score < 15


def test_rule_based_higher_trend_with_frequent_desaturations():
    spo2 = [96] * 1000
    for i in range(0, 1000, 20):
        spo2[i] = 88
    result = predict_sleep_apnea(spo2, model=None, scaler=None)
    assert result.desaturation_index_proxy > 0
    assert result.trend_level in ("Medium", "High")


def test_no_trained_model_falls_back_cleanly():
    # No sleep_apnea_model.pkl/scaler shipped — the rule-based path
    # never raises.
    result = predict_sleep_apnea([95] * 200, model=None, scaler=None)
    assert result.trend_level in ("Low", "Medium", "High")
    # class_probabilities is only populated by the ML path.
    assert result.class_probabilities is None
from app.ml.sleep_apnea import MIN_SPO2_SAMPLES, compute_odi, predict_sleep_apnea


def test_insufficient_data_below_threshold():
    result = predict_sleep_apnea(spo2_night=[96] * 50)
    assert result.risk_level == "Insufficient data"


def test_compute_odi_stable_spo2_is_zero():
    spo2 = [96] * 200
    assert compute_odi(spo2) == 0


def test_compute_odi_detects_desaturations():
    spo2 = [96] * 500
    # Inject a handful of clear desaturation events (>3 below the ~96 baseline).
    for i in range(50, 450, 80):
        spo2[i] = 90
    odi = compute_odi(spo2)
    assert odi > 0


def test_rule_based_low_risk_stable_spo2():
    result = predict_sleep_apnea(spo2_night=[96] * MIN_SPO2_SAMPLES)
    assert result.risk_level == "Low"
    assert result.risk_score < 15


def test_rule_based_higher_risk_with_frequent_desaturations():
    spo2 = [96] * 1000
    for i in range(0, 1000, 20):  # frequent desaturations
        spo2[i] = 88
    result = predict_sleep_apnea(spo2, model=None, scaler=None)
    assert result.odi > 0
    assert result.risk_level in ("Medium", "High")


def test_no_trained_model_falls_back_cleanly():
    # No sleep_apnea_model.pkl/scaler shipped — confirms the documented
    # fallback path (see ml/sleep_apnea.py) never raises.
    result = predict_sleep_apnea([95] * 200, model=None, scaler=None)
    assert result.risk_level in ("Low", "Medium", "High")
    assert result.class_probabilities is None

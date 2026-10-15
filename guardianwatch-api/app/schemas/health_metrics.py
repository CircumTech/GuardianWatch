"""
Result shapes for the ML insight models.

Every class here carries WELLNESS / ENGINEERING indicators. None is a
clinical measurement or diagnosis. Field names deliberately avoid the
word "probability" and clinical metric acronyms (ODI) — mobile's
post-claims-policy `health_metrics.dart` defines the same field names so
the two surfaces stay in lockstep.
"""
from pydantic import BaseModel, ConfigDict


class HRVMetricsOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    rmssd: float
    sdnn: float
    stress_score: float
    stress_level: str
    recovery_status: str


class AFibResultOut(BaseModel):
    """
    NOT a probability of AFib. An engineering irregularity indicator
    in [0, 1]. Field name mirrors mobile's `AFibResult.irregularityIndicator`.
    """
    irregularity_indicator: float
    is_suspected: bool
    confidence: str


class OxygenDesaturationTrendOut(BaseModel):
    """
    NOT a clinical Oxygen Desaturation Index. An engineering proxy
    count of overnight SpO₂ dips per hour. Field names mirror mobile's
    `OxygenDesaturationTrend`.

    `class_probabilities` is an additive field only produced by the
    ML path when the XGBoost model is loaded. Mobile's `fromJson`
    ignores unknown fields, so this is safe to include.
    """
    desaturation_index_proxy: float
    trend_score: float
    trend_level: str
    recommendation: str
    class_probabilities: list[float] | None = None
SleepApneaRiskOut = OxygenDesaturationTrendOut

class FeverResultOut(BaseModel):
    """
    Wrist temperature ≠ core temperature. `deviation_score` is a
    deviation from personal baseline, NOT a probability of infection.
    """
    current_temp: float
    baseline_temp: float
    deviation_score: float
    is_suspected: bool
    recommendation: str


class FatigueResultOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    fatigue_score: float
    readiness: str
    resting_hr_trend: str
    recommendation: str
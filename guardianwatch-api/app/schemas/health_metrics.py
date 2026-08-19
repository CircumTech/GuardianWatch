"""
Pydantic response shapes for each ML insight, field-for-field matched to
the Dart classes in `lib/models/health_metrics.dart` so `X.fromJson()` on
the Flutter side parses these without any changes.
"""
from pydantic import BaseModel, ConfigDict


class HRVMetricsOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    rmssd: float
    sdnn: float
    stress_score: float
    stress_level: str  # "Low" | "Medium" | "High" | "Insufficient data"
    recovery_status: str


class AFibResultOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    probability: float
    is_suspected: bool
    confidence: str  # "Low" | "Medium" | "High"


class SleepApneaRiskOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    odi: float
    risk_score: float
    risk_level: str  # "Low" | "Medium" | "High" | "Insufficient data"
    recommendation: str
    # Extra, optional — only populated when the trained XGBoost model (not
    # just the rule-based fallback) produced the prediction. Dart's
    # `SleepApneaRisk.fromJson` ignores unknown keys, so this is additive
    # and never breaks the existing app.
    class_probabilities: list[float] | None = None


class FeverResultOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    current_temp: float
    baseline_temp: float
    probability: float
    is_suspected: bool
    recommendation: str


class FatigueResultOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    fatigue_score: float
    readiness: str
    resting_hr_trend: str
    recommendation: str

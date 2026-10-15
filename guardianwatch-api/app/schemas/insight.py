import datetime as dt
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

Severity = Literal["normal", "caution", "warning", "critical"]


class InsightBase(BaseModel):
    """Shared fields across inbound and outbound insight shapes.

    Mirrors `lib/models/insight.dart::Insight` after the claims-policy
    review. Titles avoid clinical terminology; severities use the four
    values mobile reads via `InsightSeverity.values.firstWhere(...)`.
    """
    title: str = Field(..., min_length=1, max_length=255)
    summary: str = Field(..., min_length=1)
    detail: str = Field(..., min_length=1)
    severity: Severity = "normal"
    is_premium: bool = False
    recommendation: str | None = None


class InsightIn(InsightBase):
    """An insight as sent BY the client to POST /insights/save.

    The Dart app computes these on-device today
    (`generateDailyInsights()` in insight_provider.dart) and persists
    them here. The two provenance fields are optional because older
    app builds didn't send them.
    """
    id: str = Field(..., min_length=1, max_length=64)
    generated_at: dt.datetime
    health_record_id: str | None = Field(default=None, max_length=64)
    algorithm_version: str | None = Field(default=None, max_length=64)


class InsightOut(InsightBase):
    """An insight as returned BY the API."""
    model_config = ConfigDict(from_attributes=True)

    id: str
    generated_at: dt.datetime
    # Provenance — required by the report's Model Governance section:
    # "Model version stored with every result."
    health_record_id: str | None = None
    algorithm_version: str | None = None


class InsightsSaveRequest(BaseModel):
    """Body for POST /insights/save — matches `ApiService.saveInsights`,
    which sends `{'insights': [Insight.toJson(), ...]}`."""
    insights: list[InsightIn] = Field(..., max_length=200)


class GenerateInsightsRequest(BaseModel):
    """
    Optional body for POST /insights/generate.

    Mobile currently sends nothing; the endpoint works with an empty
    body. These fields allow a future client to override what is not
    sensor-derived.
    """
    age: int | None = Field(default=None, ge=13, le=120)
    bmi: float | None = Field(default=None, ge=10.0, le=80.0)
    sleep_hours: float | None = Field(default=None, ge=0.0, le=24.0)
    hr_recovery: float | None = Field(default=None, ge=0.0, le=100.0)
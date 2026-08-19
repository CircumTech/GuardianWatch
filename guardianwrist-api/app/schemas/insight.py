import datetime as dt
from typing import Literal

from pydantic import BaseModel, ConfigDict

Severity = Literal["normal", "caution", "warning", "critical"]


class InsightBase(BaseModel):
    """Field-for-field match to `Insight.toJson()`/`fromJson()` in insight.dart."""
    title: str
    summary: str
    detail: str
    severity: Severity = "normal"
    is_premium: bool = False
    recommendation: str | None = None


class InsightIn(InsightBase):
    """
    An insight as sent BY the client to POST /insights/save. The Dart app
    still computes these on-device today (`generateDailyInsights()` in
    insight_provider.dart) and just persists them here — this endpoint
    keeps that flow working unchanged.
    """
    id: str
    generated_at: dt.datetime


class InsightOut(InsightBase):
    """An insight as returned BY the API (GET /insights/latest,
    POST /insights/generate, POST /insights/save)."""
    model_config = ConfigDict(from_attributes=True)

    id: str
    generated_at: dt.datetime


class InsightsSaveRequest(BaseModel):
    """Body for POST /insights/save — matches `ApiService.saveInsights`,
    which sends `{'insights': [Insight.toJson(), ...]}`."""
    insights: list[InsightIn]


class GenerateInsightsRequest(BaseModel):
    """
    Optional body for POST /insights/generate. The current Dart client
    sends no body at all (see `ApiService.generateInsights`) — the endpoint
    works fine with none of this set, pulling everything it needs from the
    user's recent `readings`. These are here so a future client (or the
    Swagger UI) can override what isn't sensor-derived.
    """
    age: int | None = None
    bmi: float | None = None
    sleep_hours: float | None = None
    hr_recovery: float | None = None

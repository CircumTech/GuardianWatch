"""
ECG inference endpoint.

`POST /ecg/analyze` returns an ENGINEERING IRREGULARITY INDICATOR, not a
probability of AFib. The response model `AFibResultOut` carries the
`irregularity_indicator` field, aligned with mobile's
`AFibResult.irregularityIndicator`.

This is an optional endpoint. Mobile runs the same inference on-device
via `InsightProvider.analyzeEcgRhythm()`. Use this endpoint only if you
want server-side inference as an alternative to bundling the TFLite
asset with the app.

A separate endpoint `POST /ecg_sessions` (persistence of ECG session
metadata) is not implemented here. If ECG session recording is wired
into the mobile app, that endpoint needs to be added on the backend to
receive `{id, device_id, started_at, ended_at, sample_rate, ...}`
payloads from `DeviceProvider`.
"""
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from app.dependencies import get_current_premium_user, get_model_registry
from app.ml import afib as ml_afib
from app.ml.model_registry import ModelRegistry
from app.models.user import User
from app.rate_limit import limiter
from app.schemas.health_metrics import AFibResultOut

router = APIRouter(prefix="/ecg", tags=["ecg"])

# 4 seconds at 250 Hz — matches `MIN_SAMPLES_FOR_ML` in `app/ml/afib.py`.
# Shorter segments cannot produce a stable RR series and always fall
# through to the rule-based path, which itself requires ≥5 R-peaks.
_MIN_ECG_SAMPLES = 1000

# ~17 minutes at 250 Hz. Bounds request size — a caller cannot POST a
# 100 MB JSON body and force the interpreter to resize it.
_MAX_ECG_SAMPLES = 250_000


class EcgAnalyzeRequest(BaseModel):
    ecg_mv: list[float] = Field(
        ...,
        min_length=_MIN_ECG_SAMPLES,
        max_length=_MAX_ECG_SAMPLES,
        description=(
            "Raw ECG samples in millivolts, "
            "≥4 seconds at 250 Hz (≥1000 samples)."
        ),
    )


@router.post("/analyze", response_model=AFibResultOut)
@limiter.limit("30/minute")
async def analyze_ecg(
    request: Request,  # required by @limiter.limit
    body: EcgAnalyzeRequest,
    user: User = Depends(get_current_premium_user),
    registry: ModelRegistry = Depends(get_model_registry),
):
    """
    Runs the AFib/rhythm-irregularity inference on a raw ECG segment.

    Premium-gated — matches the premium flag on the mobile
    "Irregular Rhythm Pattern" insight card.

    Rate-limited: this endpoint invokes the TFLite interpreter, which is
    CPU-bound. A premium user can still hammer it without a rate limit.
    """
    return ml_afib.predict_afib(body.ecg_mv, registry)
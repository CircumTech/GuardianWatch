"""
POST /ecg/analyze — bonus endpoint, not in the current Dart contract.

`detectAFibFromSegment()` in insight_provider.dart runs this check
entirely on-device today via the CV-heuristic rule (or the bundled tflite
model, when present as a Flutter asset). This gives the app a way to get
the same immediate yes/no back from the server instead — using the exact
same trained CNN this backend already loads for /insights/generate — for
a heavier or more accurate check than shipping the model as an app asset.
Wiring it up client-side is optional.
"""
from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from app.dependencies import get_current_premium_user, get_model_registry
from app.ml import afib as ml_afib
from app.ml.model_registry import ModelRegistry
from app.models.user import User
from app.schemas.health_metrics import AFibResultOut

router = APIRouter(prefix="/ecg", tags=["ecg"])


class EcgAnalyzeRequest(BaseModel):
    ecg_mv: list[float] = Field(..., min_length=10, description="Raw ECG samples, millivolts")


@router.post("/analyze", response_model=AFibResultOut)
async def analyze_ecg(
    body: EcgAnalyzeRequest,
    user: User = Depends(get_current_premium_user),  # AFib is a premium insight, same as the card
    registry: ModelRegistry = Depends(get_model_registry),
):
    return ml_afib.predict_afib(body.ecg_mv, registry)

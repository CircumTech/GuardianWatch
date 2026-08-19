"""Liveness/readiness probe — what Cloud Run (or any orchestrator) polls."""
from fastapi import APIRouter, Depends, Request

from app.dependencies import get_model_registry
from app.ml.model_registry import ModelRegistry

router = APIRouter(tags=["health"])


@router.get("/health")
async def health_check(registry: ModelRegistry = Depends(get_model_registry)):
    return {
        "status": "ok",
        "models": registry.status(),
    }

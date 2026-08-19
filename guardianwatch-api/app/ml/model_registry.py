"""
Loads every trained model artifact exactly once, at process startup, and
holds them in memory for the life of the process — never re-read from disk
per-request. `main.py`'s lifespan handler owns the single instance
(`app.state.models`); routers reach it via `Depends(get_model_registry)`.

Every model here is *optional* at load time. If a `.pkl` is missing or a
tflite backend can't be imported, the registry logs it and moves on — the
corresponding `ml/*.py` module falls back to a rule-based implementation
rather than the whole API failing to boot. This mirrors the same
graceful-degradation pattern already in `insight_model_service.dart`
(on-device rule-based fallback when the AFib tflite model isn't loaded).
"""
from __future__ import annotations

import logging
from pathlib import Path
from typing import Any

import joblib

from app.config import get_settings

logger = logging.getLogger("guardianwrist.ml")


class ModelRegistry:
    def __init__(self, model_dir: Path):
        self.model_dir = model_dir

        self.stress_model: Any | None = None
        self.fatigue_model: Any | None = None
        self.fever_detector: Any | None = None

        self.afib_interpreter: Any | None = None
        self.afib_input_index: int | None = None
        self.afib_output_index: int | None = None
        self.afib_backend: str = "unavailable"

        self.sleep_apnea_model: Any | None = None
        self.sleep_apnea_scaler: Any | None = None

    # ── loading ──────────────────────────────────────────────────────────
    def load(self) -> None:
        self._load_sklearn_models()
        self._load_afib_interpreter()
        self._load_sleep_apnea()

    def _load_sklearn_models(self) -> None:
        for attr, filename in (
            ("stress_model", "stress_model.pkl"),
            ("fatigue_model", "fatigue_model.pkl"),
            ("fever_detector", "fever_detector.pkl"),
        ):
            path = self.model_dir / filename
            try:
                setattr(self, attr, joblib.load(path))
                logger.info("Loaded %s from %s", attr, path)
            except FileNotFoundError:
                logger.warning(
                    "%s not found at %s — falling back to rule-based scoring", attr, path
                )
            except Exception:
                logger.exception("Failed to load %s from %s", attr, path)

    def _load_afib_interpreter(self) -> None:
        """
        Tries the lightest available TFLite runtime first. Order matters:
        `ai-edge-litert` (~58MB, actively maintained successor to
        tflite-runtime) → `tflite_runtime` (legacy, spotty wheel
        availability) → full `tensorflow` (heavy, but works anywhere TF is
        already a dependency) → none, meaning `ml/afib.py` uses the
        RR-interval rule-based fallback instead.
        """
        tflite_path = self.model_dir / "afib_detection.tflite"
        if not tflite_path.exists():
            logger.warning("afib_detection.tflite not found — AFib checks use rule-based fallback")
            return

        interpreter = None
        backend = "unavailable"

        try:
            from ai_edge_litert.interpreter import Interpreter  # type: ignore

            interpreter = Interpreter(model_path=str(tflite_path))
            backend = "ai_edge_litert"
        except ImportError:
            try:
                from tflite_runtime.interpreter import Interpreter  # type: ignore

                interpreter = Interpreter(model_path=str(tflite_path))
                backend = "tflite_runtime"
            except ImportError:
                try:
                    import tensorflow as tf  # type: ignore

                    interpreter = tf.lite.Interpreter(model_path=str(tflite_path))
                    backend = "tensorflow"
                except ImportError:
                    logger.warning(
                        "No TFLite backend available (tried ai-edge-litert, "
                        "tflite_runtime, tensorflow) — AFib checks use rule-based fallback"
                    )
                    return

        try:
            interpreter.allocate_tensors()
            self.afib_input_index = interpreter.get_input_details()[0]["index"]
            self.afib_output_index = interpreter.get_output_details()[0]["index"]
            self.afib_interpreter = interpreter
            self.afib_backend = backend
            logger.info("Loaded AFib tflite model via %s", backend)
        except Exception:
            logger.exception("Failed to initialize AFib interpreter")

    def _load_sleep_apnea(self) -> None:
        """
        `sleep_apnea_model.pkl` / `sleep_apnea_scaler.pkl` were not present
        in the uploaded project (only `sleep_apena.py`'s *training* code
        was). If you train and drop both files into `app/models_store/`,
        they'll be picked up automatically on next boot — no code changes
        needed. Until then, `ml/sleep_apnea.py` uses a rule-based scorer
        built on the same ODI feature engineering.
        """
        model_path = self.model_dir / "sleep_apnea_model.pkl"
        scaler_path = self.model_dir / "sleep_apnea_scaler.pkl"
        if model_path.exists() and scaler_path.exists():
            try:
                self.sleep_apnea_model = joblib.load(model_path)
                self.sleep_apnea_scaler = joblib.load(scaler_path)
                logger.info("Loaded sleep apnea model + scaler")
            except Exception:
                logger.exception("Failed to load sleep apnea model/scaler")
        else:
            logger.info(
                "sleep_apnea_model.pkl/scaler not present — using rule-based sleep apnea scoring"
            )

    # ── introspection ────────────────────────────────────────────────────
    def status(self) -> dict[str, str]:
        """Powers GET /health's `models` block — quick way to confirm
        what's actually live in a given deployment."""
        return {
            "stress_model": "loaded" if self.stress_model is not None else "rule_based_fallback",
            "fatigue_model": "loaded" if self.fatigue_model is not None else "rule_based_fallback",
            "fever_detector": "loaded" if self.fever_detector is not None else "rule_based_fallback",
            "afib_model": f"loaded ({self.afib_backend})" if self.afib_interpreter is not None else "rule_based_fallback",
            "sleep_apnea_model": "loaded" if self.sleep_apnea_model is not None else "rule_based_fallback",
        }


_registry: ModelRegistry | None = None


def build_model_registry() -> ModelRegistry:
    """Called once from `main.py`'s lifespan handler."""
    global _registry
    settings = get_settings()
    _registry = ModelRegistry(settings.MODEL_DIR)
    _registry.load()
    return _registry

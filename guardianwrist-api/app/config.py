"""
Central application configuration.

Everything here is overridable via environment variables (or a `.env` file
in the project root — see `.env.example`). Nothing secret is hard-coded.
"""
from functools import lru_cache
from pathlib import Path
from typing import List

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

BASE_DIR = Path(__file__).resolve().parent.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # ── App ──────────────────────────────────────────────────────────────
    APP_NAME: str = "GuardianWrist API"
    ENV: str = Field(default="development")  # development | staging | production
    DEBUG: bool = Field(default=True)
    API_V1_PREFIX: str = ""  # kept empty so routes match the Flutter app's
    # existing contract exactly (e.g. `/readings`, not `/api/v1/readings`).

    # ── Database ─────────────────────────────────────────────────────────
    # Defaults to a local SQLite file so `uvicorn app.main:app` works with
    # zero setup. Point this at Cloud SQL / any Postgres instance in prod:
    #   postgresql+asyncpg://user:password@host:5432/guardianwrist
    DATABASE_URL: str = Field(
        default="sqlite+aiosqlite:///./guardianwrist.db"
    )
    DATABASE_ECHO: bool = Field(default=False)

    # ── Auth ─────────────────────────────────────────────────────────────
    # Firebase project that issues the ID tokens the Flutter app sends to
    # POST /auth/token. Must match `firebase_options.dart`.
    FIREBASE_PROJECT_ID: str = Field(default="guardianwatch-b1972")
    # Path to a Firebase service-account JSON key. If unset, the Admin SDK
    # falls back to Application Default Credentials (the right choice when
    # running on Cloud Run with a service account attached).
    FIREBASE_CREDENTIALS_PATH: str | None = Field(default=None)

    # Backend-issued JWT (what `ApiService._jwt()` stores and sends as
    # `Authorization: Bearer <token>` on every call after /auth/token).
    JWT_SECRET_KEY: str = Field(
        default="dev-only-insecure-secret-change-me"
    )
    JWT_ALGORITHM: str = Field(default="HS256")
    JWT_EXPIRE_MINUTES: int = Field(default=60 * 24 * 30)  # 30 days — see README

    # ── CORS ─────────────────────────────────────────────────────────────
    CORS_ORIGINS: List[str] = Field(default_factory=lambda: ["*"])

    # ── ML models ────────────────────────────────────────────────────────
    MODEL_DIR: Path = Field(default=BASE_DIR / "app" / "models_store")

    # ── In-app purchase receipt verification ────────────────────────────
    APPLE_SHARED_SECRET: str | None = Field(default=None)
    APPLE_VERIFY_URL: str = Field(
        default="https://buy.itunes.apple.com/verifyReceipt"
    )
    APPLE_VERIFY_URL_SANDBOX: str = Field(
        default="https://sandbox.itunes.apple.com/verifyReceipt"
    )
    GOOGLE_PLAY_SERVICE_ACCOUNT_PATH: str | None = Field(default=None)
    GOOGLE_PLAY_PACKAGE_NAME: str = Field(default="com.circumnet.guardianwrist")

    # ── Rate limiting ────────────────────────────────────────────────────
    RATE_LIMIT_AUTH: str = Field(default="10/minute")
    RATE_LIMIT_DEFAULT: str = Field(default="120/minute")


@lru_cache
def get_settings() -> Settings:
    """Settings are read once and cached — avoids re-parsing env on every request."""
    return Settings()

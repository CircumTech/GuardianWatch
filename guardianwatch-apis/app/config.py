"""
Central application configuration.

Everything here is overridable via environment variables (or a `.env` file
in the project root — see `.env.example`). Nothing secret is hard-coded,
and the validators below refuse to boot in non-development environments
with placeholder secrets, wildcard CORS, or SQLite.
"""
from functools import lru_cache
from pathlib import Path
from typing import List

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

BASE_DIR = Path(__file__).resolve().parent.parent

_DEV_JWT_SECRET = "dev-only-insecure-secret-change-me"
_DEV_ADMIN_SECRET = "dev-only-insecure-admin-secret-change-me"


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
    DATABASE_URL: str = Field(
        default="sqlite+aiosqlite:///./guardianwrist.db"
    )
    DATABASE_ECHO: bool = Field(default=False)

    # ── Auth ─────────────────────────────────────────────────────────────
    FIREBASE_PROJECT_ID: str = Field(default="guardianwatch-b1972")
    FIREBASE_CREDENTIALS_PATH: str | None = Field(default=None)

    JWT_SECRET_KEY: str = Field(default=_DEV_JWT_SECRET)
    JWT_ALGORITHM: str = Field(default="HS256")
    # 24h, not 30d. Mobile transparently refreshes via Firebase on 401, so
    # this is invisible to the user — and it caps the blast radius of a
    # stolen token since there is no server-side revocation list.
    JWT_EXPIRE_MINUTES: int = Field(default=60 * 24)

    # ── Admin panel auth ─────────────────────────────────────────────────
    # Deliberately a SEPARATE secret from JWT_SECRET_KEY (see
    # models/admin_user.py for why) — a customer token must never be
    # decodable with this key, and vice versa. Generate independently:
    #   python -c "import secrets; print(secrets.token_urlsafe(48))"
    ADMIN_JWT_SECRET_KEY: str = Field(default=_DEV_ADMIN_SECRET)
    ADMIN_JWT_EXPIRE_MINUTES: int = Field(default=60 * 12)

    # Operator token for the readiness probe. Optional. When set, callers
    # presenting it in the X-Health-Token header receive the detailed
    # model-status block from GET /readyz. When unset, only DEBUG builds
    # see the detailed response.
    HEALTH_TOKEN: str | None = Field(default=None)

    # ── Payments (Stripe) ────────────────────────────────────────────────
    STRIPE_SECRET_KEY: str | None = Field(default=None)
    STRIPE_WEBHOOK_SECRET: str | None = Field(default=None)
    FRONTEND_URL: str = Field(default="http://localhost:5173")

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

    # ─────────────────────────────────────────────────────────────────────
    # Production hardening — refuses to start with dev defaults in prod.
    # Any of these failing surfaces at boot, not on the first request.
    # ─────────────────────────────────────────────────────────────────────

    @model_validator(mode="after")
    def _enforce_production_safety(self) -> "Settings":
        if self.ENV == "development":
            return self

        # Secrets must be non-default and non-trivial in length.
        secret_checks = {
            "JWT_SECRET_KEY": (self.JWT_SECRET_KEY, _DEV_JWT_SECRET),
            "ADMIN_JWT_SECRET_KEY": (self.ADMIN_JWT_SECRET_KEY, _DEV_ADMIN_SECRET),
        }
        for field, (value, placeholder) in secret_checks.items():
            if value == placeholder:
                raise ValueError(
                    f"{field} must be set to a unique value in {self.ENV}. "
                    "Generate with: python -c \"import secrets; "
                    "print(secrets.token_urlsafe(48))\""
                )
            if len(value) < 32:
                raise ValueError(
                    f"{field} must be at least 32 characters in {self.ENV} "
                    f"(got {len(value)})."
                )

        # The two secrets must differ from each other, not just from defaults.
        if self.JWT_SECRET_KEY == self.ADMIN_JWT_SECRET_KEY:
            raise ValueError(
                "JWT_SECRET_KEY and ADMIN_JWT_SECRET_KEY must be different. "
                "Otherwise a customer token could be replayed against the "
                "admin API."
            )

        # CORS must be explicit.
        if "*" in self.CORS_ORIGINS:
            raise ValueError(
                f"CORS_ORIGINS must not contain '*' in {self.ENV}. "
                "List explicit origins instead."
            )

        # Database must not be ephemeral.
        if "sqlite" in self.DATABASE_URL:
            raise ValueError(
                f"SQLite is not supported in {self.ENV}. "
                "Set DATABASE_URL to a Postgres URL "
                "(e.g. postgresql+asyncpg://...)."
            )

        return self


@lru_cache
def get_settings() -> Settings:
    """Settings are read once and cached — avoids re-parsing env on every request."""
    return Settings()
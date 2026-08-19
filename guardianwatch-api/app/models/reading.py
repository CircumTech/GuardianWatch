"""
Reading model — one row per *raw* sensor event uploaded from the wristband.

Important: this mirrors `SensorData` in the Flutter app, not `HealthRecord`.
Looking at `ble_service.dart::_parseBytes`, each BLE characteristic
notification (HR, SpO2, temperature, ECG, battery) arrives as its own
`SensorData` with only ONE field populated and the rest null — the app
never actually assembles a complete HR+SpO2+temp triple on the wire. So we
store readings exactly as partial events, and coalesce them into complete
`HealthRecord`-shaped rows at read time (see `services/reading_service.py`).
This is also why the table is called `readings`, distinct from the
`health_records` shape the API still serves at `GET /readings` for
backwards compatibility with the existing app contract.
"""
import datetime as dt

from sqlalchemy import Float, ForeignKey, Index, Integer, JSON, String
from sqlalchemy.orm import Mapped, mapped_column, relationship
from app.utils.db_types import UTCDateTime

from app.database import Base


class Reading(Base):
    __tablename__ = "readings"
    __table_args__ = (
        Index("ix_readings_user_recorded", "user_id", "recorded_at"),
    )

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    user_id: Mapped[str] = mapped_column(
        String(128), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )

    heart_rate: Mapped[int | None] = mapped_column(Integer, nullable=True)
    spo2: Mapped[int | None] = mapped_column(Integer, nullable=True)
    temperature: Mapped[float | None] = mapped_column(Float, nullable=True)
    # Stored as JSON (list[float]) rather than a separate table — BLE MTU
    # limits mean each notification carries only a few dozen samples, so
    # this stays small per row. See README for the scale-out note
    # (TimescaleDB / a dedicated time-series store) if raw ECG volume grows.
    ecg_mv: Mapped[list[float] | None] = mapped_column(JSON, nullable=True)
    battery: Mapped[int | None] = mapped_column(Integer, nullable=True)

    recorded_at: Mapped[dt.datetime] = mapped_column(
        UTCDateTime(), nullable=False, index=True
    )
    created_at: Mapped[dt.datetime] = mapped_column(
        UTCDateTime(), default=lambda: dt.datetime.now(dt.timezone.utc)
    )

    user: Mapped["User"] = relationship(back_populates="readings")  # noqa: F821

import datetime as dt

from pydantic import BaseModel, ConfigDict, Field


class SensorDataIn(BaseModel):
    """
    One raw BLE event, mirroring `SensorData.toJson()` in sensor_data.dart.

    Per `ble_service.dart::_parseBytes`, a real device notification only
    ever populates ONE of heart_rate/spo2/temperature/ecg_mv/battery at a
    time — the rest arrive null. That's expected and fine; this is why
    ingestion and the coalesced history view are separate concerns (see
    `services/reading_service.py`).
    """

    id: str | None = None
    heart_rate: int | None = None
    spo2: int | None = None
    temperature: float | None = None
    ecg_mv: list[float] | None = None
    battery: int | None = None
    timestamp: dt.datetime


class ReadingsUploadRequest(BaseModel):
    """Body for POST /readings — matches `ApiService.uploadReadings`,
    which sends `{'readings': [SensorData.toJson(), ...]}`."""
    readings: list[SensorDataIn] = Field(default_factory=list)


class ReadingsUploadResponse(BaseModel):
    accepted: int


class HealthRecordOut(BaseModel):
    """Matches `HealthRecord.fromJson()` in health_record.dart exactly."""
    model_config = ConfigDict(from_attributes=True)

    id: str
    user_id: str
    heart_rate: int
    spo2: int
    temperature: float
    recorded_at: dt.datetime


class ReadingsSummaryOut(BaseModel):
    """
    Bonus endpoint (GET /readings/summary) — not part of the existing Dart
    contract, but a direct server-side equivalent of the avg/min/max HR
    math `dashboard_provider.dart` currently does client-side over the
    full record list. Saves payload size and client CPU once wired up.
    """
    range_from: dt.datetime
    range_to: dt.datetime
    count: int
    avg_hr: float | None = None
    min_hr: int | None = None
    max_hr: int | None = None
    avg_spo2: float | None = None
    min_spo2: int | None = None
    avg_temp: float | None = None

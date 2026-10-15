import datetime as dt

from pydantic import BaseModel, ConfigDict, Field, field_validator

# Mobile's BleService already rejects out-of-range samples before they
# enter the pipeline, but the backend is the source of truth. Bounds here
# mirror `ble_service.dart` so a buggy or malicious client cannot pollute
# a user's history (and the ML models that read it) with garbage.
_HR_MIN, _HR_MAX = 20, 240
_SPO2_MIN, _SPO2_MAX = 50, 100
_TEMP_MIN, _TEMP_MAX = 0.0, 60.0
_BATT_MIN, _BATT_MAX = 0, 100

# Mobile batches at AppConstants.maxApiBatchSize (100). 500 leaves
# headroom without inviting a DoS-sized request body.
_MAX_BATCH_SIZE = 500


class SensorDataIn(BaseModel):
    """
    One raw BLE event.

    Matches BOTH shapes the mobile app can send:
      - `SensorData.toJson()` from the deprecated ApiService.uploadReadings
        path (uses `timestamp`)
      - `HealthRecord.toJson()` from the current ApiService.uploadHealthRecords
        path (uses `recorded_at`)

    `recorded_at` is accepted as an alias for `timestamp` so either payload
    parses without a mobile-side change.
    """

    id: str | None = None

    heart_rate: int | None = Field(default=None, ge=_HR_MIN, le=_HR_MAX)
    spo2: int | None = Field(default=None, ge=_SPO2_MIN, le=_SPO2_MAX)
    temperature: float | None = Field(default=None, ge=_TEMP_MIN, le=_TEMP_MAX)
    ecg_mv: list[float] | None = None
    battery: int | None = Field(default=None, ge=_BATT_MIN, le=_BATT_MAX)

    # Extra fields the mobile HealthRecord payload carries that we don't
    # currently persist but should not reject.
    device_id: str | None = None
    session_id: str | None = None
    signal_quality: int | None = Field(default=None, ge=0, le=100)

    # `recorded_at` from HealthRecord.toJson(), `timestamp` from the
    # legacy SensorData.toJson() — both arrive as ISO8601 UTC.
    timestamp: dt.datetime = Field(..., alias="recorded_at")

    model_config = ConfigDict(populate_by_name=True, extra="ignore")

    @field_validator("timestamp")
    @classmethod
    def _require_timezone(cls, v: dt.datetime) -> dt.datetime:
        if v.tzinfo is None:
            raise ValueError(
                "timestamp must be timezone-aware (ISO8601 with offset or Z)"
            )
        return v


class ReadingsUploadRequest(BaseModel):
    """
    Body for POST /readings.

    Accepts both keys the mobile app has used across revisions:
      - `{"records": [...]}` from the current uploadHealthRecords path
      - `{"readings": [...]}` from the deprecated uploadReadings path

    Uses a validator rather than an alias because Pydantic cannot express
    "either of two field names" directly.
    """

    records: list[SensorDataIn] | None = Field(
        default=None, max_length=_MAX_BATCH_SIZE
    )
    readings: list[SensorDataIn] | None = Field(
        default=None, max_length=_MAX_BATCH_SIZE
    )

    model_config = ConfigDict(extra="ignore")

    @property
    def effective_readings(self) -> list[SensorDataIn]:
        # Prefer `records` (current mobile path); fall back to `readings`.
        if self.records is not None:
            return self.records
        return self.readings or []


class ReadingsUploadResponse(BaseModel):
    accepted: int


class HealthRecordOut(BaseModel):
    """
    Response shape for GET /readings. Matches
    `HealthRecord.fromJson()` in health_record.dart. Fields mobile treats
    as nullable are nullable here too.
    """

    model_config = ConfigDict(from_attributes=True)

    id: str
    user_id: str
    heart_rate: int
    spo2: int | None = None
    temperature: float | None = None
    battery: int | None = None
    device_id: str | None = None
    session_id: str | None = None
    recorded_at: dt.datetime
    created_at: dt.datetime | None = None


class ReadingsSummaryOut(BaseModel):
    range_from: dt.datetime
    range_to: dt.datetime
    count: int
    avg_hr: float | None = None
    min_hr: int | None = None
    max_hr: int | None = None
    avg_spo2: float | None = None
    min_spo2: int | None = None
    avg_temp: float | None = None
import datetime as dt
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, computed_field

from app.schemas.product import ProductOut

# Constrains `device_id` at the schema boundary. Prevents empty strings,
# oversized payloads, and arbitrary characters from reaching the query
# layer. Pattern matches what `generate_device_id` produces — the two
# must stay in sync.
#
# 4 to 32 chars, uppercase alphanumerics plus hyphen. The lower bound
# rejects `""`, `"x"`, and other trivially invalid inputs before they
# hit the database. The upper bound matches the model's `String(32)`.
DEVICE_ID_PATTERN = r"^[A-Z0-9-]{4,32}$"

# Constrained to the `DeviceStatus` enum values so clients receive a
# 422 if the backend ever returns an unexpected string, rather than
# silently rendering it.
DeviceStatusLiteral = Literal["unregistered", "registered", "deactivated"]


class DeviceBase(BaseModel):
    """
    Shared shape for both authenticated and public device views.

    Deliberately excludes `owner_user_id` — a device ID is by design
    shareable for authenticity checks, and nothing about who owns a
    specific physical unit should leak through any response.
    """
    model_config = ConfigDict(from_attributes=True)

    id: str
    product: ProductOut
    status: DeviceStatusLiteral
    firmware_version: str | None = None
    registered_at: dt.datetime | None = None
    warranty_months: int

    @computed_field  # type: ignore[prop-decorator]
    @property
    def warranty_active(self) -> bool:
        """
        True if the warranty period is still running.

        Warranty is measured from `registered_at` — the day the customer
        paired the device — not `manufactured_at`. Standard industry
        practice; a device that sat on a shelf for a year does not lose
        that year off its customer-facing warranty.
        """
        if self.registered_at is None:
            return False
        # 30-day months are an approximation. For a 12-month warranty
        # the worst-case error is 1 day per year, immaterial for a
        # warranty claim window.
        expires = self.registered_at + dt.timedelta(days=30 * self.warranty_months)
        return dt.datetime.now(dt.timezone.utc) < expires


class DeviceLookupOut(DeviceBase):
    """
    Public "look up your device" result.

    Same shape as `DeviceOut` by design — the fields that matter for
    authenticity checks (product, status, warranty) are identical, and
    there is no owner information in either. Defined as a subclass so
    future additions to `DeviceBase` apply to both views.
    """


class DeviceOut(DeviceBase):
    """
    Authenticated "my devices" result.

    Same shape as `DeviceLookupOut` today. The two are separate classes
    so a future field can be added to one without leaking into the
    other — e.g. a "last_synced_at" that only the owner should see.
    """


class DeviceRegisterRequest(BaseModel):
    """
    Body for POST /devices/register.

    `device_id` is validated against the same pattern that constrains
    the model column. Rejects empty strings, oversized payloads, and
    arbitrary characters at the schema boundary — before the value
    reaches the query layer.
    """
    device_id: str = Field(
        ...,
        pattern=DEVICE_ID_PATTERN,
        description="The code printed on the unit (uppercase alphanumerics and hyphens).",
        examples=["GW-A1B2C3D4E5F6"],
    )
"""
Device — one row per physical unit.

Created at provisioning time (before sale) via
`scripts/provision_devices.py`, then claimed by a customer when they
first pair it. `id` is the code printed on the unit — the "special id"
the company site's device-lookup page and the BLE first-pair flow both
use.

Deliberately the cloud-side half of the pairing flow: on first BLE
connection the app calls `POST /devices/register` with this same id,
which flips the device from `unregistered` to `registered` and attaches
it to the signed-in user — see routers/devices.py.

STATUS LIFECYCLE

  unregistered to registered to unregistered  (via /reset)
                       │
                        to deactivated          (via admin / RMA)

A `deactivated` device is intentionally NOT re-registerable: it
represents a unit reported lost, stolen, or returned. Reactivating
requires an admin action. The router enforces this.
"""
import datetime as dt
import enum

from sqlalchemy import Enum, ForeignKey, Index, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base
from app.utils.db_types import UTCDateTime
from app.utils.device_id import generate_device_id


class DeviceStatus(str, enum.Enum):
    unregistered = "unregistered"  # provisioned, never claimed by a customer
    registered = "registered"      # claimed — has an owner
    deactivated = "deactivated"    # reported lost/stolen, or returned/RMA


class Device(Base):
    __tablename__ = "devices"
    __table_args__ = (
        # `GET /devices/mine` filters on owner_user_id. Foreign keys in
        # Postgres do not auto-create an index, so the query would table
        # scan without this.
        Index("ix_devices_owner_user_id", "owner_user_id"),
    )

    id: Mapped[str] = mapped_column(
        String(32),
        primary_key=True,
        # `generate_device_id` must return ≤ 32 characters, or this
        # column will truncate on insert. `uuid4().hex` is exactly 32;
        # `str(uuid4())` is 36 and would fail. See app/utils/device_id.py.
        default=generate_device_id,
    )
    product_id: Mapped[str] = mapped_column(
        String(64),
        ForeignKey("products.id", ondelete="RESTRICT"),
        nullable=False,
    )
    status: Mapped[DeviceStatus] = mapped_column(
        Enum(DeviceStatus, native_enum=False, length=16),
        default=DeviceStatus.unregistered,
        nullable=False,
    )
    owner_user_id: Mapped[str | None] = mapped_column(
        String(128),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )

    firmware_version: Mapped[str | None] = mapped_column(String(32), nullable=True)
    warranty_months: Mapped[int] = mapped_column(
        Integer, default=12, nullable=False
    )

    manufactured_at: Mapped[dt.datetime] = mapped_column(
        UTCDateTime(),
        default=lambda: dt.datetime.now(dt.timezone.utc),
        nullable=False,
    )
    registered_at: Mapped[dt.datetime | None] = mapped_column(
        UTCDateTime(), nullable=True
    )

    product: Mapped["Product"] = relationship(back_populates="devices")  # noqa: F821
    owner: Mapped["User | None"] = relationship(back_populates="devices")  # noqa: F821
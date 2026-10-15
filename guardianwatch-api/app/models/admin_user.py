"""
AdminUser — internal staff accounts.

Deliberately a separate table and a separate auth system from the
customer-facing `User` (which is keyed by Firebase uid and never has a
password on this side at all).

Why separate rather than an `is_admin` flag on `User`:
  - A flag-on-User design means one bug in one permission check is the
    only thing standing between a customer session and admin access.
    Two different tables, two different JWT secrets (see security.py),
    and two different login flows mean a customer token structurally
    *cannot* satisfy the admin dependency, regardless of any flag value
    — the "restriction wall" is enforced by the data model, not just by
    application logic that could have a bug in it.
  - Admins are staff, not customers — they don't have (or need) a
    Firebase identity, and shouldn't share a namespace with people who
    bought a watch.
"""
import datetime as dt
import uuid

from sqlalchemy import Boolean, String
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base
from app.utils.db_types import UTCDateTime


class AdminUser(Base):
    __tablename__ = "admin_users"

    # Explicit default so a direct insert (from `scripts/create_admin.py`
    # or a test fixture) never has to remember to generate the id. Uses
    # `uuid4().hex` (32 chars) rather than `str(uuid4())` (36 chars with
    # dashes) — the 36-char form is what most tools use by default, but
    # hex is shorter and still collision-free at any realistic scale.
    id: Mapped[str] = mapped_column(
        String(36),
        primary_key=True,
        default=lambda: uuid.uuid4().hex,
    )

    email: Mapped[str] = mapped_column(
        String(320), unique=True, index=True, nullable=False
    )
    hashed_password: Mapped[str] = mapped_column(String(255), nullable=False)
    display_name: Mapped[str] = mapped_column(String(255), nullable=False)

    # Single role today ("admin") — kept as a column rather than a bare
    # boolean so a future split (e.g. "owner" vs "support_staff" with
    # narrower permissions) doesn't need a schema migration to introduce,
    # just a new value and new checks against it. The allowed values are
    # constrained by `AdminRoleLiteral` in schemas/admin.py.
    role: Mapped[str] = mapped_column(
        String(32), default="admin", nullable=False
    )

    is_active: Mapped[bool] = mapped_column(
        Boolean, default=True, nullable=False
    )

    created_at: Mapped[dt.datetime] = mapped_column(
        UTCDateTime(),
        default=lambda: dt.datetime.now(dt.timezone.utc),
        nullable=False,
    )
    updated_at: Mapped[dt.datetime] = mapped_column(
        UTCDateTime(),
        default=lambda: dt.datetime.now(dt.timezone.utc),
        onupdate=lambda: dt.datetime.now(dt.timezone.utc),
        nullable=False,
    )
    last_login_at: Mapped[dt.datetime | None] = mapped_column(
        UTCDateTime(), nullable=True
    )
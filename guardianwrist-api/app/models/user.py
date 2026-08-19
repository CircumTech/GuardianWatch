"""
User model.

The primary key is the Firebase UID — the same `uid` the Flutter app
already uses to key its Firestore `users/{uid}` document (see
`auth_service.dart`). We don't duplicate Firestore; this table only holds
what *this* API needs to do its job (own the readings/insights FKs, gate
premium features, and answer GET /me).
"""
import datetime as dt

from sqlalchemy import Boolean, String, Integer
from sqlalchemy.orm import Mapped, mapped_column, relationship
from app.utils.db_types import UTCDateTime

from app.database import Base


class User(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(128), primary_key=True)  # Firebase uid
    email: Mapped[str | None] = mapped_column(String(320), nullable=True, index=True)
    display_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    photo_url: Mapped[str | None] = mapped_column(String(1024), nullable=True)
    email_verified: Mapped[bool] = mapped_column(Boolean, default=False)

    # Optional profile fields — the app's profile_screen.dart collects these
    # today but writes them straight to Firestore. Exposed here too so a
    # future version of the app (or this API) can personalize ML inputs
    # (e.g. sleep-apnea risk takes age/bmi) without a Firestore round trip.
    age: Mapped[int | None] = mapped_column(Integer, nullable=True)
    gender: Mapped[str | None] = mapped_column(String(32), nullable=True)
    bmi: Mapped[float | None] = mapped_column(nullable=True)

    premium: Mapped[bool] = mapped_column(Boolean, default=False)
    premium_expires_at: Mapped[dt.datetime | None] = mapped_column(
        UTCDateTime(), nullable=True
    )

    created_at: Mapped[dt.datetime] = mapped_column(
        UTCDateTime(), default=lambda: dt.datetime.now(dt.timezone.utc)
    )
    last_login_at: Mapped[dt.datetime] = mapped_column(
        UTCDateTime(), default=lambda: dt.datetime.now(dt.timezone.utc)
    )

    readings: Mapped[list["Reading"]] = relationship(  # noqa: F821
        back_populates="user", cascade="all, delete-orphan"
    )
    insights: Mapped[list["Insight"]] = relationship(  # noqa: F821
        back_populates="user", cascade="all, delete-orphan"
    )
    subscriptions: Mapped[list["Subscription"]] = relationship(  # noqa: F821
        back_populates="user", cascade="all, delete-orphan"
    )

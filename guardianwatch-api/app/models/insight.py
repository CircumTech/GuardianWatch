"""
Insight model — mirrors `lib/models/insight.dart::Insight` field for field,
including the `severity` enum names (`normal|caution|warning|critical`)
which the Dart side parses with `InsightSeverity.values.firstWhere(...)`.
"""
import datetime as dt
import enum

from sqlalchemy import Boolean, Enum, ForeignKey, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship
from app.utils.db_types import UTCDateTime

from app.database import Base


class InsightSeverity(str, enum.Enum):
    normal = "normal"
    caution = "caution"
    warning = "warning"
    critical = "critical"


class Insight(Base):
    __tablename__ = "insights"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    user_id: Mapped[str] = mapped_column(
        String(128), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )

    title: Mapped[str] = mapped_column(String(255), nullable=False)
    summary: Mapped[str] = mapped_column(Text, nullable=False)
    detail: Mapped[str] = mapped_column(Text, nullable=False)
    severity: Mapped[InsightSeverity] = mapped_column(
        Enum(InsightSeverity, native_enum=False, length=16),
        default=InsightSeverity.normal,
    )
    is_premium: Mapped[bool] = mapped_column(Boolean, default=False)
    recommendation: Mapped[str | None] = mapped_column(Text, nullable=True)

    generated_at: Mapped[dt.datetime] = mapped_column(
        UTCDateTime(), nullable=False, index=True
    )
    created_at: Mapped[dt.datetime] = mapped_column(
        UTCDateTime(), default=lambda: dt.datetime.now(dt.timezone.utc)
    )

    user: Mapped["User"] = relationship(back_populates="insights")  # noqa: F821

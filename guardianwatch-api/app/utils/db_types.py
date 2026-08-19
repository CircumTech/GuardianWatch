"""
A `DateTime` that's always UTC-aware, both going in and coming out.

SQLite has no native timestamp type — `DateTime(timezone=True)` on SQLite
silently drops tzinfo on read-back even though the value was written with
a UTC offset (PostgreSQL via asyncpg does not have this problem). Since
local dev defaults to SQLite (see config.py's `DATABASE_URL`), every
timestamp column in this project uses `UTCDateTime` instead of raw
`DateTime(timezone=True)`, so reads are correct regardless of backend —
fixed once, at the type level, rather than at every call site that reads
a timestamp back out.
"""
import datetime as dt

from sqlalchemy import DateTime
from sqlalchemy.types import TypeDecorator


class UTCDateTime(TypeDecorator):
    impl = DateTime(timezone=True)
    cache_ok = True

    def process_bind_param(self, value: dt.datetime | None, dialect) -> dt.datetime | None:
        if value is not None and value.tzinfo is None:
            value = value.replace(tzinfo=dt.timezone.utc)
        return value

    def process_result_value(self, value: dt.datetime | None, dialect) -> dt.datetime | None:
        if value is not None and value.tzinfo is None:
            value = value.replace(tzinfo=dt.timezone.utc)
        return value

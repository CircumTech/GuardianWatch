"""
A `DateTime` that is always UTC, both going in and coming out.

SQLite has no native timestamp type — `DateTime(timezone=True)` on
SQLite silently drops tzinfo on read-back even though the value was
written with a UTC offset (PostgreSQL via asyncpg does not have this
problem). Since local dev defaults to SQLite (see config.py's
`DATABASE_URL`), every timestamp column in this project uses
`UTCDateTime` instead of raw `DateTime(timezone=True)`, so reads are
correct regardless of backend — fixed once, at the type level, rather
than at every call site that reads a timestamp back out.

CONVENTIONS

  On write:
    - Naive datetime to assumed UTC.
    - Aware datetime, any timezone → converted to UTC.
    - `None` to stored as `NULL`.

  On read:
    - Returns a UTC-aware datetime.
    - Never returns a naive datetime.

If a caller passes a naive datetime, we assume UTC rather than raising,
because the alternative — raising — would mean every call site has to
remember to attach `tzinfo=timezone.utc` before storing. The mobile app
already sends `toUtc().toIso8601String()` on every timestamp, and
`datetime.now()` in backend code is called with `tz=timezone.utc`
explicitly throughout. The assumption is safe.
"""
import datetime as dt

from sqlalchemy import DateTime
from sqlalchemy.types import TypeDecorator

_UTC = dt.timezone.utc


class UTCDateTime(TypeDecorator):
    impl = DateTime(timezone=True)
    cache_ok = True

    def process_bind_param(
        self, value: dt.datetime | None, dialect
    ) -> dt.datetime | None:
        """
        Called before the value is handed to the DB driver.

        Normalizes every datetime to UTC:
          - Naive values are assumed to be UTC and labelled as such.
          - Aware values in any timezone are converted to UTC.

        Without the second case, a caller passing an `Asia/Lagos`-aware
        datetime would leave that offset in the stored value on SQLite,
        and every UTC-bounded range query afterwards would silently miss
        the row.
        """
        if value is None:
            return None

        if value.tzinfo is None:
            # Assume UTC — see module docstring for the rationale.
            return value.replace(tzinfo=_UTC)

        # Aware value: convert to UTC. `astimezone` handles the DST
        # arithmetic; the previous `.replace(tzinfo=...)` shortcut would
        # have been wrong for anything not already UTC.
        return value.astimezone(_UTC)

    def process_result_value(
        self, value: dt.datetime | None, dialect
    ) -> dt.datetime | None:
        """
        Called on the value returned by the DB driver.

        Guarantees a UTC-aware datetime out, regardless of what the
        driver hands us:
          - Naive (SQLite's usual case) → label as UTC.
          - Aware but not UTC (rare; asyncpg always normalizes) →
            convert to UTC.
        """
        if value is None:
            return None

        if value.tzinfo is None:
            return value.replace(tzinfo=_UTC)

        return value.astimezone(_UTC)
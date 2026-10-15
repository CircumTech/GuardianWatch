"""
Async SQLAlchemy engine/session setup.

Works against SQLite (local dev, zero config) or PostgreSQL (production —
recommended: Cloud SQL for Postgres behind Cloud Run) purely by changing
DATABASE_URL. No code here is Postgres- or SQLite-specific.
"""
from collections.abc import AsyncGenerator

from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase

from app.config import get_settings

settings = get_settings()

# `connect_args` only matters for SQLite (disables the same-thread check so
# the async driver can hand connections across the event loop); Postgres
# via asyncpg ignores unknown kwargs of this shape so it's safe either way.
_connect_args = (
    {"check_same_thread": False} if "sqlite" in settings.DATABASE_URL else {}
)

engine = create_async_engine(
    settings.DATABASE_URL,
    echo=settings.DATABASE_ECHO,
    connect_args=_connect_args,
    pool_pre_ping=True,
)

AsyncSessionLocal = async_sessionmaker(
    bind=engine,
    autoflush=False,
    autocommit=False,
    expire_on_commit=False,
)


class Base(DeclarativeBase):
    pass


async def get_db() -> AsyncGenerator[AsyncSession, None]:
    """FastAPI dependency — yields a session, guarantees close, rolls back on error."""
    async with AsyncSessionLocal() as session:
        try:
            yield session
        except Exception:
            await session.rollback()
            raise


async def init_db() -> None:
    """
    Create tables that don't exist yet.

    Handy for local dev / first boot. For production schema changes, use
    Alembic migrations (`alembic upgrade head`) instead of relying on this —
    see alembic/README in this project.
    """
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

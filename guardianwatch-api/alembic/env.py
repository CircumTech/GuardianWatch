"""
Async-aware Alembic environment.

Pulls `DATABASE_URL` from the same `app.config.get_settings()` every
other part of the app uses, so migrations always target whatever
database the application would connect to — no separate migration-only
connection string to keep in sync.

Two subtleties worth knowing:

  • `set_main_option` goes through Python's `ConfigParser`, which treats
    `%` as an interpolation marker. A URL-encoded password containing
    `%` (extremely common — `p@ss%40word`) must have that `%` doubled to
    `%%`, or alembic raises `ValueError: invalid interpolation syntax`.

  • `render_as_batch=True` makes every operation emit SQLite-compatible
    batch mode (recreate-table-and-copy). SQLite lacks `ALTER COLUMN`,
    `DROP COLUMN` (before 3.35), and most `ADD CONSTRAINT` support.
    Without this, plain alembic operations fail on SQLite even though
    they work fine on Postgres.
"""
import asyncio
import sys
from logging.config import fileConfig
from pathlib import Path

from sqlalchemy import pool
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import async_engine_from_config

from alembic import context

# Make the project root importable so `from app...` works when alembic is
# invoked from anywhere.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.config import get_settings  # noqa: E402
from app.database import Base  # noqa: E402

# Importing the models package registers every mapped class on
# `Base.metadata`. This ONLY works if `app/models/__init__.py` imports
# every model module — see the check below.
from app import models  # noqa: E402,F401

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

settings = get_settings()

# Double every `%` — ConfigParser interpolation. A password of
# `p@ss%40word` would otherwise blow up with a cryptic error.
config.set_main_option(
    "sqlalchemy.url",
    settings.DATABASE_URL.replace("%", "%%"),
)

target_metadata = Base.metadata


def _assert_all_models_loaded() -> None:
    """
    Fails fast if a model module exists on disk but wasn't imported into
    `Base.metadata`. Without this check, `alembic revision --autogenerate`
    proposes dropping tables that aren't registered — which is silent
    data-loss-shaped behavior in a migration diff.

    The check compares table names declared in `Base.metadata` against
    the module names in `app/models/`. It cannot catch a mismatch between
    a model class and its `__tablename__`, but it catches the common case
    of forgetting to add a module to `app/models/__init__.py`.
    """
    models_dir = Path(__file__).resolve().parents[1] / "app" / "models"
    module_names = {
        p.stem
        for p in models_dir.glob("*.py")
        if p.stem not in ("__init__",)
    }
    registered = {mapper.class_.__module__.split(".")[-1] for mapper in Base.registry.mappers}
    missing = module_names - registered
    if missing:
        raise RuntimeError(
            "Some model modules are not imported into Base.metadata: "
            f"{sorted(missing)}. Add them to `app/models/__init__.py` "
            "before running alembic — otherwise autogenerate will propose "
            "dropping their tables."
        )


def run_migrations_offline() -> None:
    """
    `alembic upgrade head --sql` — emits SQL for review without a live
    DB connection. Useful for producing a migration script to run
    manually on a database where alembic itself cannot connect.
    """
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        render_as_batch=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection: Connection) -> None:
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        # SQLite compatibility: table-recreate batch mode for ALTER
        # operations the engine doesn't support in place.
        render_as_batch=True,
        # Compare column types on autogenerate so a widened VARCHAR
        # shows up as a change.
        compare_type=True,
        # Compare server defaults too.
        compare_server_default=True,
    )
    with context.begin_transaction():
        context.run_migrations()


async def run_migrations_online() -> None:
    connectable = async_engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)
    await connectable.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    _assert_all_models_loaded()
    asyncio.run(run_migrations_online())
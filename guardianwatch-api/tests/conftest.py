"""
Shared fixtures. The integration fixtures spin up a fresh in-memory
SQLite DB per test and mock Firebase verification (this environment has
no network route to Firebase — see receipt_service.py's docstring for the
same constraint on the IAP tests, which are intentionally not included
here since they'd need real Apple/Google sandbox credentials).
"""
import datetime as dt
from unittest.mock import patch
import sys
from pathlib import Path
ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.append(str(ROOT_DIR))

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
from app.database import Base, get_db
from app.ml.model_registry import build_model_registry
from app.main import app as fastapi_app


@pytest_asyncio.fixture
async def db_session():
    """A fresh in-memory SQLite DB per test — fast, isolated, no file cleanup."""
    engine = create_async_engine("sqlite+aiosqlite:///:memory:", connect_args={"check_same_thread": False})
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    session_maker = async_sessionmaker(bind=engine, expire_on_commit=False)

    async with session_maker() as session:
        yield session

    await engine.dispose()


@pytest_asyncio.fixture
async def client(db_session):
    """An AsyncClient wired to the real app, with the DB dependency
    overridden to use the isolated per-test database and Firebase
    verification mocked (see module docstring)."""

    async def _get_db_override():
        yield db_session

    fastapi_app.dependency_overrides[get_db] = _get_db_override
    fastapi_app.state.models = build_model_registry()

    transport = ASGITransport(app=fastapi_app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac

    fastapi_app.dependency_overrides.clear()


@pytest_asyncio.fixture
async def auth_headers(client):
    """Signs in a fake user and returns ready-to-use auth headers."""
    with patch("app.security.verify_firebase_id_token") as mock_verify:
        mock_verify.return_value = {
            "uid": "test-user-1",
            "email": "test@example.com",
            "name": "Test User",
            "picture": None,
            "email_verified": True,
        }
        r = await client.post("/auth/token", json={"id_token": "fake-token"})
        assert r.status_code == 200
        token = r.json()["access_token"]
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def now():
    return dt.datetime.now(dt.timezone.utc)

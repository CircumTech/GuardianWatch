import datetime as dt

import pytest


class TestHealth:
    async def test_health_check(self, client):
        r = await client.get("/health")
        assert r.status_code == 200
        assert r.json()["status"] == "ok"
        assert "stress_model" in r.json()["models"]


class TestAuth:
    async def test_exchange_token_creates_user(self, client):
        from unittest.mock import patch

        with patch("app.security.verify_firebase_id_token") as mock_verify:
            mock_verify.return_value = {
                "uid": "new-user", "email": "new@example.com",
                "name": "New User", "picture": None, "email_verified": True,
            }
            r = await client.post("/auth/token", json={"id_token": "fake"})
        assert r.status_code == 200
        body = r.json()
        assert "access_token" in body  # the one field the Dart client requires
        assert body["user"]["id"] == "new-user"

    async def test_protected_endpoint_without_token_rejected(self, client):
        r = await client.get("/readings")
        assert r.status_code in (401, 403)

    async def test_protected_endpoint_with_garbage_token_rejected(self, client):
        r = await client.get("/me", headers={"Authorization": "Bearer not-a-real-token"})
        assert r.status_code == 401


class TestReadings:
    async def test_upload_returns_201(self, client, auth_headers, now):
        payload = {"readings": [{"heart_rate": 60, "timestamp": now.isoformat()}]}
        r = await client.post("/readings", json=payload, headers=auth_headers)
        assert r.status_code == 201
        assert r.json()["accepted"] == 1

    async def test_get_readings_returns_bare_array(self, client, auth_headers, now):
        r = await client.get("/readings", headers=auth_headers)
        assert r.status_code == 200
        assert isinstance(r.json(), list)  # contract requires a bare array, not {"data": [...]}

    async def test_coalesced_history_round_trip(self, client, auth_headers, now):
        # Offsets must stay in the past relative to the GET call below —
        # the endpoint defaults its query window to end at "now", so a
        # future-dated reading would (correctly) fall outside it.
        readings = [
            {"heart_rate": 62, "timestamp": (now - dt.timedelta(seconds=2)).isoformat()},
            {"spo2": 97, "timestamp": (now - dt.timedelta(seconds=1)).isoformat()},
            {"temperature": 36.7, "timestamp": now.isoformat()},
        ]
        r = await client.post("/readings", json={"readings": readings}, headers=auth_headers)
        assert r.status_code == 201

        r = await client.get("/readings", headers=auth_headers)
        assert r.status_code == 200
        records = r.json()
        assert len(records) >= 1
        assert records[0]["heart_rate"] == 62
        assert records[0]["spo2"] == 97
        assert records[0]["temperature"] == 36.7
        # every response datetime must carry a UTC offset, or the Dart
        # client will misinterpret it as local time (see utils/db_types.py)
        assert records[0]["recorded_at"].endswith("Z") or "+00:00" in records[0]["recorded_at"]


class TestInsights:
    async def test_generate_with_no_data_returns_insufficient_data_cards(self, client, auth_headers):
        r = await client.post("/insights/generate", headers=auth_headers)
        assert r.status_code == 200
        assert isinstance(r.json(), list)  # bare array contract

    async def test_save_client_computed_insight(self, client, auth_headers, now):
        body = {
            "insights": [{
                "id": "client-1", "title": "T", "summary": "S", "detail": "D",
                "severity": "normal", "is_premium": False,
                "generated_at": now.isoformat(), "recommendation": None,
            }]
        }
        r = await client.post("/insights/save", json=body, headers=auth_headers)
        assert r.status_code == 201

        r = await client.get("/insights/latest", headers=auth_headers)
        assert r.status_code == 200
        assert any(i["title"] == "T" for i in r.json())


class TestSubscription:
    async def test_verify_with_unconfigured_stores_returns_invalid_not_500(self, client, auth_headers):
        # Neither APPLE_SHARED_SECRET nor GOOGLE_PLAY_SERVICE_ACCOUNT_PATH
        # are set in this test environment — the endpoint should degrade
        # to "invalid" rather than 500.
        body = {"receipt": "fake-receipt-data", "product_id": "premium_monthly"}
        r = await client.post("/subscription/verify", json=body, headers=auth_headers)
        assert r.status_code == 200  # Dart client only checks for 200
        assert r.json()["status"] == "invalid"
        assert r.json()["premium"] is False

import datetime as dt

from unittest.mock import patch

import pytest


class TestHealth:
    async def test_health_check_is_liveness_only(self, client):
        r = await client.get("/health")
        assert r.status_code == 200
        assert r.json()["status"] == "ok"
        # /health is now a minimal liveness probe. The model-status
        # block moved to /readyz, gated behind DEBUG or an operator
        # token so deployment state isn't public.
        assert "models" not in r.json()

    async def test_readyz_checks_db_and_models(self, client):
        # DEBUG is on in tests, so the detailed block is returned.
        r = await client.get("/readyz")
        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "ok"
        assert "stress_model" in body["models"]


class TestAuth:
    async def test_exchange_token_creates_user(self, client):
        with patch("app.security.verify_firebase_id_token") as mock_verify:
            mock_verify.return_value = {
                "uid": "new-user",
                "email": "new@example.com",
                "name": "New User",
                "picture": None,
                "email_verified": True,
            }
            r = await client.post("/auth/token", json={"id_token": "fake"})
        assert r.status_code == 200
        body = r.json()
        assert "access_token" in body  # the field the Dart client requires
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

    async def test_upload_accepts_records_key(self, client, auth_headers, now):
        # The corrected mobile client sends `{"records": [...]}`, not
        # `{"readings": [...]}`. The schema accepts both for backward
        # compatibility.
        payload = {"records": [{"heart_rate": 62, "recorded_at": now.isoformat()}]}
        r = await client.post("/readings", json=payload, headers=auth_headers)
        assert r.status_code == 201
        assert r.json()["accepted"] == 1

    async def test_get_readings_returns_bare_array(self, client, auth_headers, now):
        r = await client.get("/readings", headers=auth_headers)
        assert r.status_code == 200
        assert isinstance(r.json(), list)

    async def test_coalesced_history_round_trip(self, client, auth_headers, now):
        readings = [
            {"heart_rate": 62, "recorded_at": (now - dt.timedelta(seconds=2)).isoformat()},
            {"spo2": 97, "recorded_at": (now - dt.timedelta(seconds=1)).isoformat()},
            {"temperature": 36.7, "recorded_at": now.isoformat()},
        ]
        r = await client.post("/readings", json={"records": readings}, headers=auth_headers)
        assert r.status_code == 201

        r = await client.get("/readings", headers=auth_headers)
        assert r.status_code == 200
        records = r.json()
        assert len(records) >= 1
        # Coalescing emits on HR presence alone. The SpO2 and Temp
        # samples that arrive within 5 minutes of the HR are attached
        # to the same record.
        assert records[0]["heart_rate"] == 62
        assert records[0]["spo2"] == 97
        assert records[0]["temperature"] == 36.7
        # Every response datetime must carry a UTC offset, or the Dart
        # client will misinterpret it as local time.
        assert records[0]["recorded_at"].endswith("Z") or "+00:00" in records[0]["recorded_at"]


class TestInsights:
    async def test_generate_with_no_data_returns_cards(self, client, auth_headers):
        r = await client.post("/insights/generate", headers=auth_headers)
        assert r.status_code == 200
        assert isinstance(r.json(), list)

    async def test_save_client_computed_insight(self, client, auth_headers, now):
        body = {
            "insights": [{
                "id": "client-1",
                "title": "T",
                "summary": "S",
                "detail": "D",
                "severity": "normal",
                "is_premium": False,
                "generated_at": now.isoformat(),
                "recommendation": None,
                "algorithm_version": "test_v1",
            }]
        }
        r = await client.post("/insights/save", json=body, headers=auth_headers)
        assert r.status_code == 201

        r = await client.get("/insights/latest", headers=auth_headers)
        assert r.status_code == 200
        assert any(i["title"] == "T" for i in r.json())
        # Provenance is now round-tripped.
        saved = next(i for i in r.json() if i["title"] == "T")
        assert saved["algorithm_version"] == "test_v1"


class TestSubscription:
    async def test_verify_with_unconfigured_stores_returns_invalid_not_500(
        self, client, auth_headers
    ):
        # Neither APPLE_SHARED_SECRET nor GOOGLE_PLAY_SERVICE_ACCOUNT_PATH
        # are set in this test environment. The endpoint degrades to a
        # clean invalid response rather than 500.
        body = {
            "receipt": "fake-receipt-data",
            "product_id": "premium_monthly",
            "platform": "ios",
        }
        r = await client.post("/subscription/verify", json=body, headers=auth_headers)
        assert r.status_code == 200
        payload = r.json()
        # The corrected response shape matches `SubscriptionVerification`
        # in api_service.dart — the mobile app reads `valid` and `active`
        # as required booleans.
        assert payload["valid"] is False
        assert payload["active"] is False
        assert payload["status"] == "invalid"

    async def test_status_endpoint_returns_inactive_when_no_subscription(
        self, client, auth_headers
    ):
        # GET /subscription/status is the mobile app's app-resume
        # reconciliation endpoint.
        r = await client.get("/subscription/status", headers=auth_headers)
        assert r.status_code == 200
        payload = r.json()
        assert payload["valid"] is False
        assert payload["active"] is False
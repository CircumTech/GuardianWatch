from app.models.admin_user import AdminUser
from app.security import hash_password


async def _seed_admin(db_session, email="admin@circum.dev", password="supersecret123", **overrides):
    admin = AdminUser(
        id=overrides.pop("id", "admin-1"),
        email=email,
        display_name="Test Admin",
        hashed_password=hash_password(password),
        **overrides,
    )
    db_session.add(admin)
    await db_session.commit()
    return admin


async def _admin_headers(client, db_session, email="admin@circum.dev", password="supersecret123"):
    await _seed_admin(db_session, email=email, password=password)
    r = await client.post("/admin/auth/login", json={"email": email, "password": password})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


class TestAdminAuth:
    async def test_login_succeeds_with_correct_password(self, client, db_session):
        headers = await _admin_headers(client, db_session)
        r = await client.get("/admin/auth/me", headers=headers)
        assert r.status_code == 200
        assert r.json()["email"] == "admin@circum.dev"

    async def test_login_fails_with_wrong_password(self, client, db_session):
        await _seed_admin(db_session, email="admin2@circum.dev", password="realpassword123")
        r = await client.post(
            "/admin/auth/login", json={"email": "admin2@circum.dev", "password": "wrongpassword"}
        )
        assert r.status_code == 401

    async def test_login_fails_for_unknown_email(self, client):
        r = await client.post(
            "/admin/auth/login", json={"email": "nobody@circum.dev", "password": "whatever12345"}
        )
        assert r.status_code == 401

    async def test_deactivated_admin_cannot_login(self, client, db_session):
        await _seed_admin(db_session, email="fired@circum.dev", password="stillhastheoldpw1", is_active=False)
        r = await client.post(
            "/admin/auth/login", json={"email": "fired@circum.dev", "password": "stillhastheoldpw1"}
        )
        assert r.status_code == 401


class TestRestrictionWall:
    """The core security property: a customer JWT must never work as an
    admin JWT, and an admin JWT must never work as a customer JWT —
    regardless of what claims either one carries."""

    async def test_customer_token_rejected_by_admin_endpoints(self, client, auth_headers):
        r = await client.get("/admin/dashboard/stats", headers=auth_headers)
        assert r.status_code == 401

    async def test_admin_token_rejected_by_customer_endpoints(self, client, db_session):
        admin_headers = await _admin_headers(client, db_session)
        r = await client.get("/me", headers=admin_headers)
        assert r.status_code == 401

    async def test_no_admin_endpoint_exposes_health_readings(self, client, db_session):
        """
        There should be no admin route under /admin/* whose path suggests
        access to a specific user's raw sensor/insight data. This walks
        the live OpenAPI schema rather than a hand-maintained list, so it
        keeps checking every future admin route too.
        """
        r = await client.get("/openapi.json")
        admin_paths = [p for p in r.json()["paths"] if p.startswith("/admin/")]
        forbidden_terms = ("reading", "ecg", "insight", "hrv", "afib")
        leaky = [p for p in admin_paths if any(term in p.lower() for term in forbidden_terms)]
        assert leaky == [], f"Found admin routes that look like they expose health data: {leaky}"


class TestAdminProducts:
    async def test_create_and_list_product(self, client, db_session):
        headers = await _admin_headers(client, db_session)
        body = {
            "id": "watch-x", "name": "Watch X", "description": "desc",
            "price_cents": 9900, "stock_quantity": 10,
        }
        r = await client.post("/admin/products", json=body, headers=headers)
        assert r.status_code == 201, r.text

        r = await client.get("/admin/products", headers=headers)
        assert any(p["id"] == "watch-x" for p in r.json())

    async def test_update_product_stock(self, client, db_session):
        headers = await _admin_headers(client, db_session)
        await client.post(
            "/admin/products",
            json={"id": "watch-y", "name": "Watch Y", "description": "d", "price_cents": 1000, "stock_quantity": 5},
            headers=headers,
        )
        r = await client.patch("/admin/products/watch-y", json={"stock_quantity": 50}, headers=headers)
        assert r.status_code == 200
        assert r.json()["stock_quantity"] == 50

    async def test_deactivate_product_hides_it_from_public_catalog(self, client, db_session):
        headers = await _admin_headers(client, db_session)
        await client.post(
            "/admin/products",
            json={"id": "watch-z", "name": "Watch Z", "description": "d", "price_cents": 1000, "stock_quantity": 5},
            headers=headers,
        )
        r = await client.delete("/admin/products/watch-z", headers=headers)
        assert r.status_code == 204

        r = await client.get("/products")
        assert all(p["id"] != "watch-z" for p in r.json())

    async def test_products_require_admin_auth(self, client):
        r = await client.get("/admin/products")
        assert r.status_code in (401, 403)


class TestAdminDevices:
    async def test_provision_creates_lookupable_devices(self, client, db_session):
        headers = await _admin_headers(client, db_session)
        await client.post(
            "/admin/products",
            json={"id": "watch-p", "name": "Watch P", "description": "d", "price_cents": 1000, "stock_quantity": 5},
            headers=headers,
        )
        r = await client.post(
            "/admin/devices/provision", json={"product_id": "watch-p", "quantity": 3}, headers=headers
        )
        assert r.status_code == 201, r.text
        devices = r.json()
        assert len(devices) == 3
        assert devices[0]["product"]["id"] == "watch-p"

        # every provisioned id is publicly look-up-able immediately
        r = await client.get(f"/devices/lookup/{devices[0]['id']}")
        assert r.status_code == 200
        assert r.json()["status"] == "unregistered"

    async def test_list_devices_includes_owner_email_for_support(self, client, db_session, auth_headers):
        admin_headers = await _admin_headers(client, db_session)
        await client.post(
            "/admin/products",
            json={"id": "watch-q", "name": "Watch Q", "description": "d", "price_cents": 1000, "stock_quantity": 5},
            headers=admin_headers,
        )
        provisioned = (
            await client.post(
                "/admin/devices/provision", json={"product_id": "watch-q", "quantity": 1}, headers=admin_headers
            )
        ).json()
        device_id = provisioned[0]["id"]
        await client.post("/devices/register", json={"device_id": device_id}, headers=auth_headers)

        r = await client.get("/admin/devices", headers=admin_headers)
        row = next(d for d in r.json() if d["id"] == device_id)
        assert row["owner_email"] == "test@example.com"  # from the auth_headers fixture's mocked user
        assert row["status"] == "registered"


class TestAuditLog:
    async def test_admin_mutations_are_logged(self, client, db_session):
        headers = await _admin_headers(client, db_session)
        await client.post(
            "/admin/products",
            json={"id": "watch-audit", "name": "W", "description": "d", "price_cents": 1000, "stock_quantity": 5},
            headers=headers,
        )
        r = await client.get("/admin/audit-log", headers=headers)
        assert r.status_code == 200
        actions = [entry["action"] for entry in r.json()]
        assert "product.create" in actions

from unittest.mock import patch

from app.models.device import Device
from app.models.product import Product


async def _seed_product(db_session, **overrides):
    defaults = dict(
        id="test-product",
        name="Test Product",
        description="A thing for sale.",
        price_cents=10000,
        currency="USD",  # uppercased
        stock_quantity=5,
    )
    defaults.update(overrides)
    product = Product(**defaults)
    db_session.add(product)
    await db_session.commit()
    return product


async def _seed_device(db_session, product_id="test-product", **overrides):
    device = Device(product_id=product_id, **overrides)
    db_session.add(device)
    await db_session.commit()
    await db_session.refresh(device)
    return device


class TestProducts:
    async def test_list_only_returns_active(self, client, db_session):
        await _seed_product(db_session, id="active-1", active=True)
        await _seed_product(db_session, id="inactive-1", active=False)

        r = await client.get("/products")
        assert r.status_code == 200
        ids = [p["id"] for p in r.json()]
        assert "active-1" in ids
        assert "inactive-1" not in ids

    async def test_in_stock_computed_field_present(self, client, db_session):
        await _seed_product(db_session, id="p1", stock_quantity=0)
        r = await client.get("/products/p1")
        assert r.status_code == 200
        assert r.json()["in_stock"] is False


class TestDevices:
    async def test_lookup_unknown_device_404(self, client):
        r = await client.get("/devices/lookup/GW-0000-0000")
        assert r.status_code == 404

    async def test_lookup_never_exposes_owner(self, client, db_session, auth_headers):
        await _seed_product(db_session)
        device = await _seed_device(db_session)

        await client.post(
            "/devices/register",
            json={"device_id": device.id},
            headers=auth_headers,
        )
        r = await client.get(f"/devices/lookup/{device.id}")
        body = r.json()
        assert "owner" not in body
        assert "owner_user_id" not in body
        assert "email" not in str(body).lower()

    async def test_cannot_register_someone_elses_device(self, client, db_session, auth_headers):
        await _seed_product(db_session)
        device = await _seed_device(db_session)
        await client.post(
            "/devices/register",
            json={"device_id": device.id},
            headers=auth_headers,
        )

        with patch("app.security.verify_firebase_id_token") as m:
            m.return_value = {
                "uid": "someone-else",
                "email": "e@x.com",
                "name": "E",
                "picture": None,
                "email_verified": True,
            }
            r = await client.post("/auth/token", json={"id_token": "fake"})
        other_headers = {"Authorization": f"Bearer {r.json()['access_token']}"}

        r = await client.post(
            "/devices/register",
            json={"device_id": device.id},
            headers=other_headers,
        )
        assert r.status_code == 409


class TestOrders:
    async def test_create_order_decrements_stock(self, client, db_session):
        await _seed_product(db_session, id="p2", stock_quantity=5, price_cents=5000)

        body = {
            "product_id": "p2",
            "quantity": 2,
            "customer_name": "A B",
            "customer_email": "ab@example.com",
            "shipping_address": {
                "street": "1 Rd",
                "city": "Lagos",
                "postal_code": "100001",
                "country": "NG",
            },
        }
        r = await client.post("/orders", json=body)
        assert r.status_code == 201
        assert r.json()["total_cents"] == 10000

        r = await client.get("/products/p2")
        assert r.json()["stock_quantity"] == 3

    async def test_order_over_stock_rejected(self, client, db_session):
        await _seed_product(db_session, id="p3", stock_quantity=1)
        body = {
            "product_id": "p3",
            "quantity": 1,
            "customer_name": "A B",
            "customer_email": "ab@example.com",
            "shipping_address": {
                "street": "1 Rd",
                "city": "Lagos",
                "postal_code": "100001",
                "country": "NG",
            },
        }
        assert (await client.post("/orders", json=body)).status_code == 201
        assert (await client.post("/orders", json=body)).status_code == 400

    async def test_order_lookup_requires_matching_email(self, client, db_session):
        await _seed_product(db_session, id="p4", stock_quantity=5)
        body = {
            "product_id": "p4",
            "quantity": 1,
            "customer_name": "A B",
            "customer_email": "real@example.com",
            "shipping_address": {
                "street": "1 Rd",
                "city": "Lagos",
                "postal_code": "100001",
                "country": "NG",
            },
        }
        order_id = (await client.post("/orders", json=body)).json()["id"]

        assert (
            await client.get(
                f"/orders/{order_id}", params={"email": "wrong@example.com"}
            )
        ).status_code == 404
        assert (
            await client.get(
                f"/orders/{order_id}", params={"email": "real@example.com"}
            )
        ).status_code == 200
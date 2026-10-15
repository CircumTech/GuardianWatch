"""
Stripe's actual API isn't reachable from this environment, so these
tests mock the SDK calls and verify *our* logic.
"""
from types import SimpleNamespace
from unittest.mock import patch

from app.models.product import Product


async def _seed_product(db_session, **overrides):
    defaults = dict(
        id="watch-pay",
        name="Watch",
        description="d",
        price_cents=15000,
        # Uppercase — the schema now enforces `^[A-Z]{3}$`.
        currency="USD",
        stock_quantity=10,
    )
    defaults.update(overrides)
    product = Product(**defaults)
    db_session.add(product)
    await db_session.commit()
    return product


async def _create_order(client, product_id="watch-pay", quantity=1):
    body = {
        "product_id": product_id,
        "quantity": quantity,
        "customer_name": "Grace Hopper",
        "customer_email": "grace@example.com",
        "shipping_address": {
            "street": "1 Compiler Way",
            "city": "Arlington",
            "postal_code": "22201",
            "country": "US",
        },
    }
    r = await client.post("/orders", json=body)
    assert r.status_code == 201, r.text
    return r.json()


class TestCheckoutSessionCreation:
    async def test_start_checkout_returns_stripe_url(self, client, db_session, monkeypatch):
        await _seed_product(db_session)
        order = await _create_order(client)

        from app.config import get_settings
        get_settings.cache_clear()
        monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_fake")

        fake_session = SimpleNamespace(
            id="cs_test_fake123",
            url="https://checkout.stripe.com/pay/cs_test_fake123",
        )
        with patch("stripe.checkout.Session.create", return_value=fake_session) as mock_create:
            # The route now requires email verification (same gate as
            # order lookup).
            r = await client.post(
                f"/orders/{order['id']}/checkout",
                params={"email": "grace@example.com"},
            )

        assert r.status_code == 200, r.text
        assert r.json()["checkout_url"] == "https://checkout.stripe.com/pay/cs_test_fake123"

        _, kwargs = mock_create.call_args
        assert kwargs["line_items"][0]["price_data"]["unit_amount"] == order["unit_price_cents"]
        assert kwargs["line_items"][0]["quantity"] == order["quantity"]
        assert kwargs["metadata"]["order_id"] == order["id"]
        assert kwargs["customer_email"] == "grace@example.com"
        get_settings.cache_clear()

    async def test_checkout_without_stripe_configured_returns_503(
        self, client, db_session, monkeypatch
    ):
        await _seed_product(db_session)
        order = await _create_order(client)

        from app.config import get_settings
        get_settings.cache_clear()
        monkeypatch.delenv("STRIPE_SECRET_KEY", raising=False)

        r = await client.post(
            f"/orders/{order['id']}/checkout",
            params={"email": "grace@example.com"},
        )
        assert r.status_code == 503
        get_settings.cache_clear()

    async def test_cannot_checkout_an_already_paid_order(
        self, client, db_session, monkeypatch
    ):
        await _seed_product(db_session, id="watch-paid")
        order = await _create_order(client, product_id="watch-paid")

        from app.config import get_settings
        get_settings.cache_clear()
        monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_fake")

        from app.models.order import Order, OrderStatus
        db_order = await db_session.get(Order, order["id"])
        db_order.status = OrderStatus.paid
        await db_session.commit()

        r = await client.post(
            f"/orders/{order['id']}/checkout",
            params={"email": "grace@example.com"},
        )
        # Router returns 409 Conflict for non-pending orders.
        assert r.status_code == 409
        get_settings.cache_clear()


class TestStripeWebhook:
    async def test_invalid_signature_rejected(self, client, monkeypatch):
        from app.config import get_settings
        get_settings.cache_clear()
        monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", "whsec_fake")

        import stripe
        with patch(
            "stripe.Webhook.construct_event",
            side_effect=stripe.SignatureVerificationError("bad sig", "sig"),
        ):
            r = await client.post(
                "/webhooks/stripe",
                content=b"{}",
                headers={"Stripe-Signature": "t=1,v1=bad"},
            )
        assert r.status_code == 400
        get_settings.cache_clear()

    async def test_completed_checkout_marks_order_paid(self, client, db_session, monkeypatch):
        await _seed_product(db_session, id="watch-webhook", price_cents=20000)
        order = await _create_order(client, product_id="watch-webhook")

        from app.config import get_settings
        get_settings.cache_clear()
        monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", "whsec_fake")

        fake_event = {
            "id": "evt_test_paid",
            "type": "checkout.session.completed",
            "data": {
                "object": {
                    "id": "cs_test_paid",
                    "metadata": {"order_id": order["id"]},
                    "client_reference_id": order["id"],
                    "amount_total": order["total_cents"],
                    "currency": "usd",
                    "payment_status": "paid",
                }
            },
        }
        with patch("stripe.Webhook.construct_event", return_value=fake_event):
            r = await client.post(
                "/webhooks/stripe",
                content=b"{}",
                headers={"Stripe-Signature": "t=1,v1=validated_by_mock"},
            )
        assert r.status_code == 200, r.text

        confirm = await client.get(
            f"/orders/{order['id']}",
            params={"email": "grace@example.com"},
        )
        body = confirm.json()
        assert body["status"] == "paid"
        # Timeline timestamps are now populated on transition.
        assert body["paid_at"] is not None
        get_settings.cache_clear()

    async def test_amount_mismatch_does_not_mark_paid(self, client, db_session, monkeypatch):
        """Defense in depth: even a validly-signed event shouldn't mark
        an order paid if the amount Stripe collected doesn't match."""
        await _seed_product(db_session, id="watch-mismatch", price_cents=5000)
        order = await _create_order(client, product_id="watch-mismatch")

        from app.config import get_settings
        get_settings.cache_clear()
        monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", "whsec_fake")

        fake_event = {
            "id": "evt_test_mismatch",
            "type": "checkout.session.completed",
            "data": {
                "object": {
                    "id": "cs_test_mismatch",
                    "metadata": {"order_id": order["id"]},
                    "client_reference_id": order["id"],
                    "amount_total": 1,  # nowhere near the real total
                    "currency": "usd",
                    "payment_status": "paid",
                }
            },
        }
        with patch("stripe.Webhook.construct_event", return_value=fake_event):
            r = await client.post(
                "/webhooks/stripe",
                content=b"{}",
                headers={"Stripe-Signature": "t=1,v1=validated_by_mock"},
            )
        assert r.status_code == 200  # webhook acks either way

        confirm = await client.get(
            f"/orders/{order['id']}",
            params={"email": "grace@example.com"},
        )
        assert confirm.json()["status"] == "pending"  # NOT flipped to paid
        get_settings.cache_clear()
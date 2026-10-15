"""
Seeds the shop with GuardianWatch products and a batch of provisioned
(unregistered) devices, so the company site's shop and device-lookup
pages have something to look at without needing an actual manufacturing
run first.

Usage:
    python scripts/seed_shop_data.py [--devices-per-product N]

Refuses to run against anything but a local SQLite DB — this is
dev/demo data, not a fixture for a real product catalog.
"""
import argparse
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.config import get_settings
from app.database import AsyncSessionLocal, init_db
from app.models.device import Device
from app.models.product import Product

settings = get_settings()


def _product_specs(product_id: str) -> dict:
    """
    Product definitions as plain dicts, not module-level model
    instances. A module-level `Product(...)` object is bound to whatever
    session first `db.add`s it — a second invocation of this script in
    the same process (tests, repeated CLI runs) raises
    `InvalidRequestError: Object '<Product>' is already attached to
    session`.
    """
    return {
        "guardianwatch-classic": dict(
            id="guardianwatch-classic",
            name="GuardianWatch Classic",
            tagline=(
                "Continuous heart, oxygen, and temperature monitoring "
                "on your wrist."
            ),
            description=(
                "GuardianWatch Classic pairs a single-lead ECG with PPG "
                "heart-rate and SpO₂ sensing, worn around the clock. "
                "On-device sensors feed a wellness analytics engine that "
                "surfaces trends in resting heart rate, overnight oxygen, "
                "skin temperature, and activity load — then explains what "
                "it found in plain language.\n\n"
                "Guardian Watch provides wellness indicators, not medical "
                "diagnoses. Consult a clinician for medical concerns."
            ),
            price_cents=14900,
            currency="USD",
            image_url="/images/guardianwatch-classic.png",
            specs={
                "Sensors": "Single-lead ECG, PPG heart-rate/SpO₂, skin temperature, 3-axis motion",
                "Battery life": "Up to 5 days typical use",
                "Charging": "USB-C, ~90 minutes to full",
                'Display': '1.28" always-on color touch display',
                "Connectivity": "Bluetooth Low Energy",
                "Water resistance": "IP67 (splash and sweat resistant, not for swimming)",
                "Companion app": "iOS & Android",
            },
            stock_quantity=42,
        ),
        "guardianwatch-pro": dict(
            id="guardianwatch-pro",
            name="GuardianWatch Pro",
            tagline=(
                "Everything in Classic, plus extended battery and a "
                "titanium case."
            ),
            description=(
                "GuardianWatch Pro is built for people who want the full "
                "picture without charging every other day. The same sensor "
                "suite as Classic, in a lighter titanium case with nearly "
                "double the battery life.\n\n"
                "Guardian Watch provides wellness indicators, not medical "
                "diagnoses. Consult a clinician for medical concerns."
            ),
            price_cents=22900,
            currency="USD",
            image_url="/images/guardianwatch-pro.png",
            specs={
                "Sensors": "Single-lead ECG, PPG heart-rate/SpO₂, skin temperature, 3-axis motion",
                "Battery life": "Up to 9 days typical use",
                "Charging": "USB-C, ~90 minutes to full",
                'Display': '1.28" always-on color touch display',
                "Case": "Titanium, 32g",
                "Connectivity": "Bluetooth Low Energy",
                "Water resistance": "IP67 (splash and sweat resistant, not for swimming)",
                "Companion app": "iOS & Android",
            },
            stock_quantity=17,
        ),
    }


PRODUCT_IDS = list(_product_specs("").keys())


async def seed(devices_per_product: int) -> None:
    if "sqlite" not in settings.DATABASE_URL:
        print(
            f"Refusing to seed non-SQLite DATABASE_URL: "
            f"{settings.DATABASE_URL}"
        )
        sys.exit(1)

    await init_db()
    specs = _product_specs("")

    async with AsyncSessionLocal() as db:
        for product_id, spec in specs.items():
            existing = await db.get(Product, product_id)
            if existing is None:
                db.add(Product(**spec))
                print(f"Created product {product_id}")
            else:
                print(f"Product {product_id} already exists, skipping")
        await db.commit()

        # Devices are provisioned only once, and only if the table is
        # empty — re-running this script should not silently inflate the
        # provisioned-unit count.
        from sqlalchemy import func, select
        existing_devices = (
            await db.execute(select(func.count()).select_from(Device))
        ).scalar_one()
        if existing_devices > 0:
            print(
                f"{existing_devices} devices already provisioned — "
                "skipping device generation. Pass --reset to clear."
            )
        else:
            created = 0
            for product_id in specs:
                for _ in range(devices_per_product):
                    db.add(Device(product_id=product_id))
                    created += 1
            await db.commit()
            print(
                f"Provisioned {created} unregistered devices across "
                f"{len(specs)} products"
            )

        # Print a few real lookup-able IDs so they're easy to try
        # immediately.
        result = await db.execute(
            select(Device.id).order_by(Device.manufactured_at.desc()).limit(5)
        )
        print("\nTry looking these up:")
        for (device_id,) in result.all():
            print(f"  {device_id}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--devices-per-product",
        type=int,
        default=10,
        help="Number of unregistered devices to create per product. "
        "Default 10.",
    )
    args = parser.parse_args()
    asyncio.run(seed(args.devices_per_product))
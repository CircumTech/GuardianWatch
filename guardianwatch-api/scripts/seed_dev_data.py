"""
Seeds the local database with a realistic stream of sensor readings for
one user, so the Flutter app (or Swagger UI) has something to look at
without needing the physical wristband connected over BLE.

Usage:
    python scripts/seed_dev_data.py <firebase-uid>

The uid should match whatever account you'll actually sign in with from
the app, so `GET /readings` etc. return data for the same user making the
request. Find it in the Firebase console, or from the `user.id` field
POST /auth/token returns after a real sign-in.

Refuses to run against anything but a local SQLite DB — this is dev-only,
not a fixture for staging/production data.
"""
import asyncio
import datetime as dt
import random
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.config import get_settings
from app.database import AsyncSessionLocal, init_db
from app.models.reading import Reading
from app.models.user import User

settings = get_settings()


async def seed(uid: str) -> None:
    if "sqlite" not in settings.DATABASE_URL:
        print(f"Refusing to seed non-SQLite DATABASE_URL: {settings.DATABASE_URL}")
        sys.exit(1)

    await init_db()
    now = dt.datetime.now(dt.timezone.utc)

    async with AsyncSessionLocal() as db:
        user = await db.get(User, uid)
        if user is None:
            user = User(id=uid, email=f"{uid}@example.com", display_name="Dev User", created_at=now, last_login_at=now)
            db.add(user)
            await db.commit()
            print(f"Created user {uid}")
        else:
            print(f"Using existing user {uid}")

        readings: list[Reading] = []

        # 3 days of HR/SpO2/Temp at realistic BLE-notification intervals.
        for i in range(3 * 24 * 60 // 2):  # every 2 minutes for 3 days
            t = now - dt.timedelta(days=3) + dt.timedelta(minutes=2 * i)
            hr = 58 + random.randint(-4, 12)
            readings.append(Reading(id=str(uuid.uuid4()), user_id=uid, heart_rate=hr, recorded_at=t))
            if i % 2 == 0:
                readings.append(Reading(id=str(uuid.uuid4()), user_id=uid, spo2=95 + random.randint(0, 3), recorded_at=t))
            if i % 15 == 0:
                temp = round(36.5 + random.uniform(-0.1, 0.2), 2)
                readings.append(Reading(id=str(uuid.uuid4()), user_id=uid, temperature=temp, recorded_at=t))

        # Overnight SpO2 for the most recent night, dense enough to clear
        # MIN_SPO2_SAMPLES in ml/sleep_apnea.py.
        for i in range(4 * 60 * 6):  # every 10s for 6 hours
            t = now - dt.timedelta(hours=7) + dt.timedelta(seconds=10 * i)
            val = 88 if i % 45 == 0 else 96 + random.randint(-1, 1)  # occasional desaturation dips
            readings.append(Reading(id=str(uuid.uuid4()), user_id=uid, spo2=val, recorded_at=t))

        # 10 days of daily resting HR, comfortably above the 7-day minimum
        # in ml/fatigue.py.
        for d in range(10):
            t = now - dt.timedelta(days=10 - d, hours=18)  # ~6am local-ish
            readings.append(Reading(id=str(uuid.uuid4()), user_id=uid, heart_rate=54 + random.randint(-2, 6), recorded_at=t))

        db.add_all(readings)
        await db.commit()
        print(f"Inserted {len(readings)} readings for {uid} spanning the last 3 days")
        print("Try: POST /insights/generate (with this user's JWT) to see real model output.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python scripts/seed_dev_data.py <firebase-uid>")
        sys.exit(1)
    asyncio.run(seed(sys.argv[1]))

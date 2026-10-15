"""
Seeds the local database with a realistic stream of sensor readings for
one user, so the Flutter app (or Swagger UI) has something to look at
without needing the physical wristband connected over BLE.

Usage:
    python scripts/seed_dev_data.py <firebase-uid> [--seed 42]

The uid should match whatever account you'll actually sign in with from
the app, so `GET /readings` etc. return data for the same user making the
request. Find it in the Firebase console, or from the `user.id` field
POST /auth/token returns after a real sign-in.

Refuses to run against anything but a local SQLite DB — this is
dev-only, not a fixture for staging/production data.
"""
import argparse
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


def _hex_uuid() -> str:
    """
    Matches the shape used everywhere else in the codebase (32-char hex,
    no dashes). `str(uuid.uuid4())` produces 36 chars with dashes, which
    fits the column but is inconsistent — and if some other code path
    assumes a fixed length, subtle bugs appear.
    """
    return uuid.uuid4().hex


async def seed(uid: str) -> None:
    if "sqlite" not in settings.DATABASE_URL:
        print(f"Refusing to seed non-SQLite DATABASE_URL: {settings.DATABASE_URL}")
        sys.exit(1)

    await init_db()
    now = dt.datetime.now(dt.timezone.utc)

    async with AsyncSessionLocal() as db:
        user = await db.get(User, uid)
        if user is None:
            user = User(
                id=uid,
                email=f"{uid}@example.com",
                display_name="Dev User",
                created_at=now,
                last_login_at=now,
            )
            db.add(user)
            await db.commit()
            print(f"Created user {uid}")
        else:
            print(f"Using existing user {uid}")

        readings: list[Reading] = []

        # ── 3 days of HR / SpO2 / Temp at BLE-notification cadence ────
        # Every 2 minutes for 3 days. SpO2 lands every 4 minutes,
        # temperature every 30.
        three_days = 3 * 24 * 60 // 2
        for i in range(three_days):
            t = now - dt.timedelta(days=3) + dt.timedelta(minutes=2 * i)
            hr = 58 + random.randint(-4, 12)
            readings.append(
                Reading(id=_hex_uuid(), user_id=uid, heart_rate=hr, recorded_at=t)
            )
            if i % 2 == 0:
                readings.append(
                    Reading(
                        id=_hex_uuid(),
                        user_id=uid,
                        spo2=95 + random.randint(0, 3),
                        recorded_at=t,
                    )
                )
            if i % 15 == 0:
                temp = round(36.5 + random.uniform(-0.1, 0.2), 2)
                readings.append(
                    Reading(
                        id=_hex_uuid(),
                        user_id=uid,
                        temperature=temp,
                        recorded_at=t,
                    )
                )

        # ── Overnight SpO2 for the most recent night ──────────────────
        # Every 10 seconds for 6 hours. Dense enough to clear
        # MIN_SPO2_SAMPLES in ml/sleep_apnea.py with margin.
        for i in range(4 * 60 * 6):
            t = now - dt.timedelta(hours=7) + dt.timedelta(seconds=10 * i)
            # Occasional desaturation dip — a real 3%+ drop from the
            # ~96 baseline, so `compute_desaturation_index` counts it.
            val = 88 if i % 45 == 0 else 96 + random.randint(-1, 1)
            readings.append(
                Reading(id=_hex_uuid(), user_id=uid, spo2=val, recorded_at=t)
            )

        # ── 10 days of daily resting HR ───────────────────────────────
        # One reading per day, timestamped to a consistent time-of-day so
        # `fetch_daily_resting_hr_trend` groups them by distinct UTC
        # dates. 10 days clears the 7-day minimum in ml/fatigue.py with
        # slack.
        #
        # `days_ago = 10 - d` counts down from 10 to 1; each is placed at
        # 22:00 UTC. The exact hour is arbitrary — the fetcher only cares
        # about distinct UTC dates.
        for d in range(10):
            days_ago = 10 - d
            t = now - dt.timedelta(days=days_ago)
            t = t.replace(hour=22, minute=0, second=0, microsecond=0)
            readings.append(
                Reading(
                    id=_hex_uuid(),
                    user_id=uid,
                    heart_rate=54 + random.randint(-2, 6),
                    recorded_at=t,
                )
            )

        db.add_all(readings)
        await db.commit()
        print(
            f"Inserted {len(readings)} readings for {uid} "
            "spanning the last ~10 days"
        )
        print(
            "Try: POST /insights/generate (with this user's JWT) to see "
            "real model output."
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("uid", help="Firebase user id to seed for")
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed for reproducible data. Default 42.",
    )
    args = parser.parse_args()

    random.seed(args.seed)
    asyncio.run(seed(args.uid))
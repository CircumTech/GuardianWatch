"""
Creates (or resets the password for) an admin account.

There is deliberately no public "sign up as admin" endpoint — see
routers/admin_auth.py. This script is run directly on the server, or via
a one-off Render shell, by whoever controls the deployment.

Usage:
    python scripts/create_admin.py owner@circum.dev "Full Name"
    (prompts for a password, hidden input)
"""
import asyncio
import getpass
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sqlalchemy import select

from app.config import get_settings
from app.database import AsyncSessionLocal
from app.models.admin_user import AdminUser
from app.security import hash_password

settings = get_settings()


async def main(email: str, display_name: str) -> None:
    normalized_email = email.strip().lower()

    # Basic shape check before hitting the DB — the model column is
    # `String(320)` and accepts anything; a typo silently creates an
    # unusable admin otherwise.
    if "@" not in normalized_email or len(normalized_email) < 3:
        print(f"Not a valid email: {email!r}")
        sys.exit(1)

    password = getpass.getpass("Password: ")
    confirm = getpass.getpass("Confirm password: ")
    if password != confirm:
        print("Passwords did not match.")
        sys.exit(1)
    if len(password) < 12:
        print(
            "Use at least 12 characters — this account can manage the "
            "entire catalog and every order."
        )
        sys.exit(1)

    # In non-development environments, schema is managed by alembic, not
    # by `init_db()`. Running `create_admin` against a production DB
    # without running migrations first is a sign something is wrong; the
    # session below will simply fail on the missing column and the
    # operator will know to run `alembic upgrade head`.
    if settings.ENV == "development":
        from app.database import init_db
        await init_db()

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(AdminUser).where(AdminUser.email == normalized_email)
        )
        existing = result.scalar_one_or_none()

        if existing:
            existing.hashed_password = hash_password(password)
            existing.display_name = display_name
            existing.is_active = True
            await db.commit()
            print(f"Updated password for existing admin {normalized_email}")
            return

        admin = AdminUser(
            # Use the same id shape the model's `default=` produces so
            # direct-insert and default-insert paths stay consistent.
            id=uuid.uuid4().hex,
            email=normalized_email,
            display_name=display_name,
            hashed_password=hash_password(password),
        )
        db.add(admin)
        await db.commit()
        print(f"Created admin account {normalized_email}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print('Usage: python scripts/create_admin.py <email> "<Display Name>"')
        sys.exit(1)
    asyncio.run(main(sys.argv[1], sys.argv[2]))
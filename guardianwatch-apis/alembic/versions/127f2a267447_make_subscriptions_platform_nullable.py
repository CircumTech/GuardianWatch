"""make_subscriptions_platform_nullable

Revision ID: 127f2a267447
Revises: 9b1701f05aae
Create Date: 2026-10-08 00:07:14.327479

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '127f2a267447'
down_revision: Union[str, None] = '9b1701f05aae'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    pass


def downgrade() -> None:
    pass

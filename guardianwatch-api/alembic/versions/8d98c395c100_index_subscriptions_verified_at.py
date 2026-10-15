"""index_subscriptions_verified_at

Revision ID: 8d98c395c100
Revises: 127f2a267447
Create Date: 2026-10-08 00:08:04.100050

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '8d98c395c100'
down_revision: Union[str, None] = '127f2a267447'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    pass


def downgrade() -> None:
    pass

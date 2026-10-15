"""harden_orders_table

Revision ID: fecc625edd46
Revises: 8d98c395c100
Create Date: 2026-10-08 01:05:25.716601

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'fecc625edd46'
down_revision: Union[str, None] = '8d98c395c100'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    pass


def downgrade() -> None:
    pass

"""add_device_id_session_id_to_readings

Revision ID: e272da8d82bc
Revises: 2a3edde9b92e
Create Date: 2026-10-07 20:28:04.998770

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'e272da8d82bc'
down_revision: Union[str, None] = '2a3edde9b92e'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    pass


def downgrade() -> None:
    pass

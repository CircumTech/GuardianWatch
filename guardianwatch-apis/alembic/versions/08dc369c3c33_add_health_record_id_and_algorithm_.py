"""add_health_record_id_and_algorithm_version_to_insights

Revision ID: 08dc369c3c33
Revises: e272da8d82bc
Create Date: 2026-10-07 21:26:30.066288

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '08dc369c3c33'
down_revision: Union[str, None] = 'e272da8d82bc'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    pass


def downgrade() -> None:
    pass
